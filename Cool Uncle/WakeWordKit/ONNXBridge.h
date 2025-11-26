//
//  ONNXBridge.h
//  WakeWordKit
//
//  Objective-C bridge for ONNX Runtime C++ API.
//  This bridge exposes ONNX Runtime functionality to Swift, including CoreML EP configuration.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ONNX Runtime session wrapper
@interface ONNXSession : NSObject

/// Initialize with model path and CoreML EP configuration
/// @param modelPath Path to ONNX model file
/// @param useCoreML Whether to use CoreML Execution Provider
/// @param error Error pointer
/// @return Initialized session or nil if failed
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                useCoreML:(BOOL)useCoreML
                                    error:(NSError **)error;

/// Run inference with Float32 input
/// @param inputData Float array input
/// @param inputSize Number of elements in input
/// @param outputSize Expected output size
/// @param error Error pointer
/// @return Output array or nil if failed
- (nullable NSArray<NSNumber *> *)runWithInput:(const float *)inputData
                                     inputSize:(NSInteger)inputSize
                                    outputSize:(NSInteger)outputSize
                                         error:(NSError **)error;

/// Get input shape
@property (nonatomic, readonly) NSArray<NSNumber *> *inputShape;

/// Get output shape
@property (nonatomic, readonly) NSArray<NSNumber *> *outputShape;

/// Get input name
@property (nonatomic, readonly) NSString *inputName;

/// Get output name
@property (nonatomic, readonly) NSString *outputName;

@end

NS_ASSUME_NONNULL_END
