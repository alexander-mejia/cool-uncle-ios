//
//  RetroGamingVocabulary.swift
//  Cool Uncle
//
//  Created for ASR customization to improve recognition of retro gaming terminology.
//  See: asr-tweak.md for rationale and testing protocol
//

import Foundation

/// Gaming vocabulary hints for speech recognition (Option 1: contextualStrings)
///
/// Provides vocabulary hints to Apple's speech recognizer to improve accuracy
/// for retro gaming terms that are frequently mistranscribed.
///
/// Usage: `recognitionRequest.contextualStrings = RetroGamingVocabulary.terms`
struct RetroGamingVocabulary {
    static let terms: [String] = [
        // === CRITICAL PRIORITY SYSTEMS ===
        // "Amiga" frequently mistranscribed as "omega"
        "Amiga",
        "Amiga CD32",
        "Amiga 500",
        "Amiga 1200",
        "Commodore Amiga",

        // "TurboGrafx-16" mistranscribed as "Turbo Graphic 16"
        "TurboGrafx-16",
        "TurboGrafx",
        "Turbo Grafx",
        "PC Engine",
        "TurboGrafx CD",

        // === HIGH PRIORITY SYSTEMS ===
        "Famicom",
        "Super Famicom",
        "ColecoVision",
        "Coleco",
        "Neo Geo",
        "NeoGeo",
        "Neo-Geo",
        "Neo Geo CD",

        // === OTHER SYSTEMS ===
        "Sega CD",
        "Sega Genesis",
        "Mega Drive",
        "Sega Master System",
        "Sega Saturn",
        "Dreamcast",
        "PlayStation",
        "PSX",
        "PS1",
        "Atari Jaguar",
        "Atari Lynx",
        "Atari 2600",
        "Atari 5200",
        "Atari 7800",
        "Atari ST",
        "Game Boy",
        "Game Boy Color",
        "Game Boy Advance",
        "GameCube",
        "Nintendo 64",
        "Super Nintendo",
        "SNES",
        "NES",
        "N64",
        "GBA",
        "Intellivision",
        "Vectrex",
        "WonderSwan",

        // === CRITICAL PRIORITY GAME TITLES ===
        // "Phantasy Star" often recognized as "fantasy star"
        "Phantasy Star",
        "Phantasy Star II",
        "Phantasy Star III",
        "Phantasy Star IV",

        // "Ys" extremely difficult - recognized as "why is", "ease"
        "Ys",
        "Ys I",
        "Ys II",
        "Ys III",

        // Other critical game titles
        "Xevious",
        "Q*bert",
        "Qbert",
        "Einhänder",
        "ToeJam & Earl",
        "ToeJam and Earl",
        "Rayman",
        "Herzog Zwei",

        // === HIGH PRIORITY GAME TITLES ===
        "Ecco the Dolphin",
        "Turrican",
        "Ninja Gaiden",
        "Earthworm Jim",
        "Gunstar Heroes",
        "Galaga",
        "R-Type",
        "ActRaiser",

        // === POPULAR GAME TITLES ===
        "Contra",
        "Castlevania",
        "Metroid",
        "Zelda",
        "The Legend of Zelda",
        "Chrono Trigger",
        "Final Fantasy",
        "Shining Force",
        "Streets of Rage",
        "Mega Man",
        "Megaman",
        "Sonic the Hedgehog",
        "Super Mario",
        "Donkey Kong",
        "Street Fighter",
        "Mortal Kombat",

        // === GAMING TERMINOLOGY ===
        "MiSTer",
        "FPGA",
        "ROM",
        "arcade",
        "cartridge",
        "joystick",
        "D-pad",
        "D pad",
        "controller",

        // === GENRE TERMS ===
        "shmup",
        "shoot 'em up",
        "beat 'em up",
        "metroidvania",
        "roguelike",
        "platformer",
        "RPG",
        "JRPG",
        "fighting game",
        "puzzle game",
        "racing game"
    ]
}
