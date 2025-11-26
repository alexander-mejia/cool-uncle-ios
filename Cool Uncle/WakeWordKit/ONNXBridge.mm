//
//  ONNXBridge.mm
//  WakeWordKit
//
//  ONNX Runtime C++ implementation with CoreML EP support.
//

#import "ONNXBridge.h"
#import <onnxruntime_cxx_api.h>
#import <coreml_provider_factory.h>  // For CoreML EP in v1.20.0
#import <vector>
#import <string>

@implementation ONNXSession {
    std::unique_ptr<Ort::Session> _session;
    std::unique_ptr<Ort::Env> _env;
    std::vector<const char*> _inputNames;
    std::vector<const char*> _outputNames;
    std::vector<int64_t> _inputShape;
    std::vector<int64_t> _outputShape;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                useCoreML:(BOOL)useCoreML
                                    error:(NSError **)error {
    self = [super init];
    if (self) {
        try {
            // Create environment
            // Use ERROR level to suppress ONNX Runtime warnings (e.g., "Invalid frame dimension")
            _env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_ERROR, "WakeWordEngine");

            // Create session options
            Ort::SessionOptions sessionOptions;

            if (useCoreML) {
                // Configure CoreML Execution Provider using C API (v1.20.0 compatible)
                // Note: v1.20.0 doesn't support the modern C++ API for CoreML
                // Must use the old C API: OrtSessionOptionsAppendExecutionProvider_CoreML

                // CoreML flags (bitwise OR of COREMLFlags from coreml_provider_factory.h)
                uint32_t coreml_flags = 0;
                coreml_flags |= COREML_FLAG_CREATE_MLPROGRAM;  // Use MLProgram (iOS 15+, Core ML 5+)
                coreml_flags |= COREML_FLAG_ONLY_ALLOW_STATIC_INPUT_SHAPES;  // Static shapes only
                // Note: COREML_FLAG_USE_CPU_AND_GPU excludes ANE
                // By not setting any CPU/GPU flags, we get default: CPU + ANE

                // Call old C API to append CoreML EP
                OrtStatus* status = OrtSessionOptionsAppendExecutionProvider_CoreML(
                    sessionOptions,  // Ort::SessionOptions can be cast to OrtSessionOptions*
                    coreml_flags
                );

                if (status != nullptr) {
                    const char* error_message = Ort::GetApi().GetErrorMessage(status);
                    NSLog(@"❌ ONNX: Failed to enable CoreML EP: %s", error_message);
                    Ort::GetApi().ReleaseStatus(status);
                } else {
                    NSLog(@"✅ ONNX: CoreML EP enabled with ANE support (v1.20.0 C API)");
                }
            } else {
                NSLog(@"ONNX: Using CPU execution (CoreML EP disabled)");
            }

            // CPU is used automatically as fallback - no need to explicitly add it

            // Optimize for inference
            sessionOptions.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);

            // Set intra/inter op threads for CPU fallback
            sessionOptions.SetIntraOpNumThreads(1); // Single thread for mobile
            sessionOptions.SetInterOpNumThreads(1);

            // Create session
            const char *modelPathCStr = [modelPath UTF8String];
            _session = std::make_unique<Ort::Session>(*_env, modelPathCStr, sessionOptions);

            // Get input/output metadata
            Ort::AllocatorWithDefaultOptions allocator;

            // Input info
            size_t numInputs = _session->GetInputCount();
            if (numInputs > 0) {
                auto inputNameAllocated = _session->GetInputNameAllocated(0, allocator);
                std::string inputName = inputNameAllocated.get();
                _inputNames.push_back(strdup(inputName.c_str()));

                auto inputTypeInfo = _session->GetInputTypeInfo(0);
                auto tensorInfo = inputTypeInfo.GetTensorTypeAndShapeInfo();
                _inputShape = tensorInfo.GetShape();
            }

            // Output info
            size_t numOutputs = _session->GetOutputCount();
            if (numOutputs > 0) {
                auto outputNameAllocated = _session->GetOutputNameAllocated(0, allocator);
                std::string outputName = outputNameAllocated.get();
                _outputNames.push_back(strdup(outputName.c_str()));

                auto outputTypeInfo = _session->GetOutputTypeInfo(0);
                auto tensorInfo = outputTypeInfo.GetTensorTypeAndShapeInfo();
                _outputShape = tensorInfo.GetShape();
            }

            NSLog(@"ONNX: Model loaded successfully");

            // Log input shape (handle variable dimensions)
            NSString *inputShapeStr = @"[";
            for (size_t i = 0; i < _inputShape.size(); i++) {
                inputShapeStr = [inputShapeStr stringByAppendingFormat:@"%lld%@", _inputShape[i], (i < _inputShape.size()-1) ? @", " : @""];
            }
            inputShapeStr = [inputShapeStr stringByAppendingString:@"]"];
            NSLog(@"ONNX: Input shape: %@", inputShapeStr);

            // Log output shape (handle variable dimensions)
            NSString *outputShapeStr = @"[";
            for (size_t i = 0; i < _outputShape.size(); i++) {
                outputShapeStr = [outputShapeStr stringByAppendingFormat:@"%lld%@", _outputShape[i], (i < _outputShape.size()-1) ? @", " : @""];
            }
            outputShapeStr = [outputShapeStr stringByAppendingString:@"]"];
            NSLog(@"ONNX: Output shape: %@", outputShapeStr);

        } catch (const Ort::Exception &e) {
            if (error) {
                *error = [NSError errorWithDomain:@"ONNXRuntime"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()]}];
            }
            return nil;
        }
    }
    return self;
}

- (nullable NSArray<NSNumber *> *)runWithInput:(const float *)inputData
                                     inputSize:(NSInteger)inputSize
                                    outputSize:(NSInteger)outputSize
                                         error:(NSError **)error {
    try {
        Ort::MemoryInfo memoryInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        // Resolve dynamic shapes at runtime
        std::vector<int64_t> runtimeInputShape = _inputShape;
        std::vector<size_t> dynamicIndices;
        int64_t knownProduct = 1;

        for (size_t i = 0; i < runtimeInputShape.size(); i++) {
            int64_t dim = runtimeInputShape[i];
            if (dim <= 0) {
                dynamicIndices.push_back(i);
            } else {
                knownProduct *= dim;
            }
        }

        if (dynamicIndices.empty()) {
            if (knownProduct != inputSize) {
                if (error) {
                    NSString *shapeDesc = @"[";
                    for (size_t i = 0; i < runtimeInputShape.size(); ++i) {
                        shapeDesc = [shapeDesc stringByAppendingFormat:@"%lld%@", runtimeInputShape[i], (i < runtimeInputShape.size() - 1) ? @", " : @"]"];
                    }
                    NSString *message = [NSString stringWithFormat:@"ONNX runtime shape mismatch. Expected %lld elements for input shape %@ but received %ld.", knownProduct, shapeDesc, (long)inputSize];
                    *error = [NSError errorWithDomain:@"ONNXRuntime"
                                                 code:-3
                                             userInfo:@{NSLocalizedDescriptionKey: message}];
                }
                return nil;
            }
        } else {
            if (knownProduct == 0) {
                knownProduct = 1;
            }

            if (inputSize % knownProduct != 0) {
                if (error) {
                    NSString *message = [NSString stringWithFormat:@"ONNX runtime cannot resolve dynamic dimensions for input of %ld elements.", (long)inputSize];
                    *error = [NSError errorWithDomain:@"ONNXRuntime"
                                                 code:-3
                                             userInfo:@{NSLocalizedDescriptionKey: message}];
                }
                return nil;
            }

            int64_t remaining = inputSize / knownProduct;

            // Assign 1 to all but the last dynamic dimension
            for (size_t idx = 0; idx + 1 < dynamicIndices.size(); ++idx) {
                runtimeInputShape[dynamicIndices[idx]] = 1;
            }

            runtimeInputShape[dynamicIndices.back()] = remaining;

            // Validate resolved shape
            int64_t resolvedProduct = 1;
            for (int64_t dim : runtimeInputShape) {
                if (dim <= 0) {
                    if (error) {
                        NSString *message = @"ONNX runtime failed to resolve dynamic input shape.";
                        *error = [NSError errorWithDomain:@"ONNXRuntime"
                                                     code:-3
                                                 userInfo:@{NSLocalizedDescriptionKey: message}];
                    }
                    return nil;
                }
                resolvedProduct *= dim;
            }

            if (resolvedProduct != inputSize) {
                if (error) {
                    NSString *shapeDesc = @"[";
                    for (size_t i = 0; i < runtimeInputShape.size(); ++i) {
                        shapeDesc = [shapeDesc stringByAppendingFormat:@"%lld%@", runtimeInputShape[i], (i < runtimeInputShape.size() - 1) ? @", " : @"]"];
                    }
                    NSString *message = [NSString stringWithFormat:@"Resolved input shape %@ does not match element count %ld.", shapeDesc, (long)inputSize];
                    *error = [NSError errorWithDomain:@"ONNXRuntime"
                                                 code:-3
                                             userInfo:@{NSLocalizedDescriptionKey: message}];
                }
                return nil;
            }
        }

        // Create input tensor with resolved shape
        Ort::Value inputTensor = Ort::Value::CreateTensor<float>(
            memoryInfo,
            const_cast<float*>(inputData),
            inputSize,
            runtimeInputShape.data(),
            runtimeInputShape.size()
        );

        // Run inference
        auto outputTensors = _session->Run(
            Ort::RunOptions{nullptr},
            _inputNames.data(),
            &inputTensor,
            1,
            _outputNames.data(),
            1
        );

        // Extract output
        float *outputData = outputTensors[0].GetTensorMutableData<float>();
        auto outputTypeAndShape = outputTensors[0].GetTensorTypeAndShapeInfo();
        size_t outputCount = outputTypeAndShape.GetElementCount();

        #ifdef DEBUG
        // Validate output for NaN/Inf (helps diagnose "Invalid frame dimension" errors)
        static int inferenceCount = 0;
        size_t nanCount = 0;
        size_t infCount = 0;
        float minVal = FLT_MAX;
        float maxVal = -FLT_MAX;

        for (size_t i = 0; i < outputCount; i++) {
            float val = outputData[i];
            if (std::isnan(val)) {
                nanCount++;
            } else if (std::isinf(val)) {
                infCount++;
            } else {
                minVal = std::min(minVal, val);
                maxVal = std::max(maxVal, val);
            }
        }

        // Log diagnostics (first few inferences or when bad data detected)
        if (inferenceCount < 3 || nanCount > 0 || infCount > 0) {
            std::vector<int64_t> actualOutputShape = outputTypeAndShape.GetShape();
            NSString *actualShapeStr = @"[";
            for (size_t i = 0; i < actualOutputShape.size(); i++) {
                actualShapeStr = [actualShapeStr stringByAppendingFormat:@"%lld%@", actualOutputShape[i], (i < actualOutputShape.size()-1) ? @", " : @""];
            }
            actualShapeStr = [actualShapeStr stringByAppendingString:@"]"];
            NSLog(@"🔍 ONNX: Inference #%d - input: %ld elements, output shape: %@, output: %zu elements",
                  inferenceCount, (long)inputSize, actualShapeStr, outputCount);
            NSLog(@"   Output validation: NaN=%zu, Inf=%zu, range=[%.4f, %.4f]",
                  nanCount, infCount, minVal == FLT_MAX ? 0.0f : minVal, maxVal == -FLT_MAX ? 0.0f : maxVal);

            if (nanCount > 0 || infCount > 0) {
                NSLog(@"⚠️ ONNX OUTPUT CONTAINS BAD VALUES! This may explain 'Invalid frame dimension' errors.");
            }
        }

        if (inferenceCount < 10) {
            inferenceCount++;
        }
        #endif

        NSMutableArray *result = [NSMutableArray arrayWithCapacity:outputCount];
        for (size_t i = 0; i < outputCount; i++) {
            [result addObject:@(outputData[i])];
        }

        return result;

    } catch (const Ort::Exception &e) {
        if (error) {
            NSString *errorMsg = [NSString stringWithFormat:@"ONNX inference error: %s", e.what()];
            *error = [NSError errorWithDomain:@"ONNXRuntime"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
            NSLog(@"%@", errorMsg);
        }
        return nil;
    }
}

- (NSArray<NSNumber *> *)inputShape {
    NSMutableArray *shape = [NSMutableArray array];
    for (int64_t dim : _inputShape) {
        [shape addObject:@(dim)];
    }
    return shape;
}

- (NSArray<NSNumber *> *)outputShape {
    NSMutableArray *shape = [NSMutableArray array];
    for (int64_t dim : _outputShape) {
        [shape addObject:@(dim)];
    }
    return shape;
}

- (NSString *)inputName {
    if (!_inputNames.empty()) {
        return [NSString stringWithUTF8String:_inputNames[0]];
    }
    return @"";
}

- (NSString *)outputName {
    if (!_outputNames.empty()) {
        return [NSString stringWithUTF8String:_outputNames[0]];
    }
    return @"";
}

- (void)dealloc {
    // Clean up allocated strings
    for (const char *name : _inputNames) {
        free((void*)name);
    }
    for (const char *name : _outputNames) {
        free((void*)name);
    }
}

@end
