# UE4SS Documentation (parsed reference)

Auto-extracted from `tools/UE4SS Documentation.pdf` (docs.ue4ss.com, print view).
Flat, searchable copy for quick reference; the PDF and docs.ue4ss.com are authoritative
for what they cover, but BOTH lag the running build. Regenerate the parsed body with
`python tools/parse_ue4ss_docs.py` after updating the PDF. Lists and code blocks lose some
formatting in PDF text extraction.

The published docs predate the game-thread Delayed Action System (RE-UE4SS PR #1128) that
this build exposes and the repo uses (`kit.async`). It is added below as a MANUAL SUPPLEMENT
(the "Delayed Action System" section) that a plain regen will NOT reproduce; re-apply it after
regenerating. Confirm any newest API against the RE-UE4SS source/PRs, not only this copy.

---

Unreal Engine 4/5 Scripting System

Lua scripting system platform, C++ Modding API, SDK generator, blueprint mod loader, live property editor and other dumping utilities for UE4/5 games.

Major features
Lua Scripting API: Write lua mods based on the UE object system Blueprint Modloading: Spawn blueprint mods automatically without editing/replacing game files C++ Modding API: Write C++ mods based on the UE object system Live Property Viewer and Editor: Search, view, edit & watch the properties of every loaded object, great for debugging mods or figuring out how values are changed during runtime UHT Dumper: Generate Unreal Header Tool compatible C++ headers for creating a mirror .uproject for your game C++ Header Dumper: Generate standard C++ headers from reflected classes and blueprints, with offsets Universal UE Mods: Unlock the game console and other universal mods Dumpers for File Parsing: Generate .usmap mapping files for unversioned properties UMAP Recreation Dumper: Dump all loaded actors to file to generate .umaps in-editor Other Features, including Experimental features at times

Targeting UE Versions: From 4.12 To 5.7
The goal of UE4SS is not to be a plug-n-play solution that always works with every game. The goal is to have an underlying system that works for most games. You may need to update AOBs on your own, and there’s a guide for that below.

## Basic Installation

The easiest installation is via downloading the non-dev version of the latest non-experimental build from Releases and extracting the zip content to {game directory}/GameName/Binaries/Win64/ .
If your game is in the custom config list, extract the contents from the relevant folder to Win64 as well.
If you are planning on doing mod development using UE4SS, you can do the same as above but download the zDEV version instead.

Command Line Options
If RE-UE4SS is installed via proxy DLL, the following command line options are available:
--disable-ue4ss - Temporarily disable UE4SS without uninstalling by launching the game with this argument. --ue4ss-path <path> - Specify a custom path to UE4SS.dll. Supports both absolute paths (e.g., C:\custom\UE4SS.dll ) and relative paths (e.g., dev\builds\UE4SS.dll relative to the game executable directory). Useful for testing different UE4SS builds without modifying installation files.

Environment Variables
RE-UE4SS supports the following environment variables:
UE4SS_MODS_PATHS - Semicolon-separated list of additional mods directories to load. Paths are processed in reverse order (first entry has highest priority), similar to the PATH variable. Example: C:\SharedMods;D:\GameMods;E:\TestMods .

Links

Full installation guide

Fixing compatibility problems

Lua API - Overview

Generating UHT compatible headers

## Custom Game Configs

Creating Compatible Blueprint Mods

UE4SS Discord Server Invite

Unreal Engine Modding Discord Server Invite

Build requirements
A computer running Windows. Linux support might happen at some point but not soon.
A version of MSVC that supports C++23: MSVC toolset version >= 14.43.0 MSVC version >= 19.43 Visual Studio version >= 17.13 More compilers will hopefully be supported in the future.
Rust toolchain >= 1.73.0 CMake >= 3.22 A build system: either Ninja or MSVC (included with Visual Studio)

Build instructions
1. Clone the repo. 2. Execute this command: git submodule update --init --
recursive Make sure your Github account is linked to your Epic Games account for UE source access. Do not use the --remote option because that will force third-party dependencies to update to the latest commit, and that can break things. You will need your github account to be linked to an Epic games account to pull the Unreal pseudo code submodule.
There are several different ways you can build UE4SS.

## Building from CLI

Build Modes
The build modes are structured as follows:
<Target>__<Config>__<Platform>
Currently supported options for these are:
Target
Game - for regular games on UE versions greater than UE 4.21 LessEqual421 - for regular games on UE versions less than or equal to UE 4.21 CasePreserving - for games built with case preserving enabled
Config
Dev - development build Debug - debug build Shipping - shipping(release) build Test - build for tests
Platform
Win64 - 64-bit windows

Basic Build Commands
To build UE4SS with CMake, use the following commands:

# Configure with Ninja (recommended for faster builds, singleconfiguration) cmake -B build_cmake_Game__Shipping__Win64 -G Ninja DCMAKE_BUILD_TYPE=Game__Shipping__Win64

# Build with Ninja cmake --build build_cmake_Game__Shipping__Win64

# Or configure with MSVC (multi-configuration, allows switching configs without reconfiguring) cmake -B build_cmake_Game__Shipping__Win64 -G "Visual Studio 17 2022"

# Build with MSVC (requires --config flag) cmake --build build_cmake_Game__Shipping__Win64 --config Game__Shipping__Win64

Configuration Options
CMake allows you to configure various build options. Here are some useful options:
Proxy Path
By default, UE4SS generates a proxy based on C:\Windows\System32\dwmapi.dll . To change this, set the CMake variable:
cmake -B build -DUE4SS_PROXY_PATH="<path to proxy dll>" DCMAKE_BUILD_TYPE=Game__Shipping__Win64

Profiler Flavor
By default, UE4SS has profiling disabled ( None ). To enable profiling, you need both a profiler flavor AND a build configuration that includes STATS:
# STATS are enabled by default in Dev and Test builds cmake -B build -DPROFILER_FLAVOR=<Tracy|Superluminal|None> DCMAKE_BUILD_TYPE=Game__Dev__Win64

Note

Profiling requires STATS support. By default, Dev and Test configurations include STATS, while Shipping and Debug do not. You can manually enable STATS for any configuration by adding compile definitions:

cmake -B build -DPROFILER_FLAVOR=Tracy DCMAKE_BUILD_TYPE=Game__Shipping__Win64 -DCMAKE_CXX_FLAGS="DSTATS"

Helpful CMake Commands

Command
cmake -B <build_dir> G <generator>
cmake --build <build_dir> cmake --build <build_dir> --config <mode> cmake --build <build_dir> --cleanfirst cmake --build <build_dir> --target <target> cmake --build <build_dir> --verbose

Description Configure the project with a specific generator (Ninja or “Visual Studio 17 2022”) Build with Ninja (single-config generator)
Build with MSVC (multi-config generator, --config required)
Clean and rebuild (add --config <mode> for MSVC)
Build a specific target (add --config <mode> for MSVC)
Build with verbose output (add -config <mode> for MSVC)

Opening in an IDE
Visual Studio CMake has built-in support for generating Visual Studio solutions:
cmake -B build -G "Visual Studio 17 2022"
Then open the generated .sln file in the build directory. Alternatively, Visual Studio 2022 has native CMake support - you can open the folder directly in Visual Studio and it will automatically detect the CMakeLists.txt file.

## CLion / Other CMake IDEs

Most modern IDEs (CLion, Visual Studio Code with CMake Tools, etc.) have native CMake support. Simply open the project folder and the IDE will automatically detect and configure the CMake project.
Note that you should also commit & push the submodules that you’ve updated if the reason why you updated was not because someone else pushed an update, and you’re just catching up to it.

Cross-Compiling Windows Binaries on Linux
UE4SS supports cross-compilation from Linux to Windows using two approaches: xwin (recommended) or msvc-wine.

Prerequisites for All Cross-Compilation Rust toolchain >= 1.73.0 with the x86_64-pc-windows-msvc target:
rustup target add x86_64-pc-windows-msvc
CMake >= 3.22 Ninja build system

Option 1: Cross-Compiling with xwin (Recommended)
xwin downloads and packages the Microsoft CRT headers/libraries and Windows SDK headers/libraries needed for cross-compilation, without requiring a Windows installation.

Prerequisites
LLVM/Clang with Windows target support:

# On Ubuntu/Debian sudo apt install clang lld llvm

# On Arch Linux sudo pacman -S clang lld llvm

xwin:

cargo install xwin

## Setup

1. Download the Microsoft tools and SDK using xwin (this only needs to be done once):

xwin --accept-license splat --output ~/.xwin

This will download approximately 300MB and can take a few minutes.
2. Set the XWIN_DIR environment variable:

export XWIN_DIR=~/.xwin

Building Manually with CMake
# Configure with xwin-clang-cl toolchain (uses clang with MSVCcompatible flags) XWIN_DIR=~/.xwin cmake -B build_xwin \
-G Ninja \ -DCMAKE_BUILD_TYPE=Game__Shipping__Win64 \ -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/xwin-clang-cltoolchain.cmake
# Or use xwin-clang toolchain (uses clang with GNU-style flags) XWIN_DIR=~/.xwin cmake -B build_xwin \
-G Ninja \ -DCMAKE_BUILD_TYPE=Game__Shipping__Win64 \ -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/xwin-clangtoolchain.cmake
# Build cmake --build build_xwin

## Building with build.sh Script

# Set XWIN_DIR export XWIN_DIR=~/.xwin
# Build with xwin-clang-cl ./tools/buildscripts/build.sh --toolchain xwin-clang-cl
# Or build with xwin-clang ./tools/buildscripts/build.sh --toolchain xwin-clang
# Build specific configuration ./tools/buildscripts/build.sh --toolchain xwin-clang-cl -build-config Game__Debug__Win64
# Clean build with verbose output ./tools/buildscripts/build.sh --toolchain xwin-clang-cl --clean --verbose

Option 2: Cross-Compiling with msvc-wine msvc-wine uses actual MSVC tools running under Wine. This provides maximum compatibility but requires more setup.
Prerequisites
Wine:
# On Ubuntu/Debian sudo apt install wine wine64 winbind
# On Arch Linux sudo pacman -S wine samba
msvc-wine - Follow their installation guide to install MSVC tools Clang (for wine-clang-cl mode) or use MSVC’s cl.exe (for wine-msvc mode)
Setup
1. Install msvc-wine following the official instructions. By default, this installs to ~/my_msvc/opt/msvc .
2. Make sure the msvc-wine tools are in your PATH:
export PATH="$HOME/my_msvc/opt/msvc/bin/x64:$PATH"

3. Set the Wine prefix (optional):

export WINE_PREFIX=~/.wine

Building Manually with CMake
# Configure with wine-clang-cl toolchain (clang-cl under wine) cmake -B build_wine \
-G Ninja \ -DCMAKE_BUILD_TYPE=Game__Shipping__Win64 \ -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/wine-clang-cltoolchain.cmake
# Or use wine-msvc toolchain (MSVC cl.exe under wine) cmake -B build_wine \
-G Ninja \ -DCMAKE_BUILD_TYPE=Game__Shipping__Win64 \ -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/wine-msvctoolchain.cmake
# Build cmake --build build_wine
Building with build.sh Script
# Build with wine-clang-cl ./tools/buildscripts/build.sh --toolchain wine-clang-cl
# Or build with wine-msvc ./tools/buildscripts/build.sh --toolchain wine-msvc
# Build specific configuration ./tools/buildscripts/build.sh --toolchain wine-clang-cl -build-config Game__Debug__Win64

Build Output
Cross-compiled binaries will be in the build directory under <BuildMode>/bin/ :
build_xwin_Game__Shipping__Win64/ └── Game__Shipping__Win64/
└── bin/ ├── UE4SS.dll ├── dwmapi.dll (proxy DLL) └── ... (other files)

## Debugging Under Wine

When using wine-based toolchains, you can debug crashes and issues using Wine’s debugger.

Using winedbg

# Debug a running program winedbg ./path/to/game.exe
# Debug a crash dump winedbg crash_2024_12_26_07_39_15.dmp

Important Notes for Debugging
Debug symbols (.pdb files) are not stored in minidump files You must have the exact same .pdb file that corresponds to the .dll that crashed The easiest way to ensure matching symbols:
1. Note the git commit hash when you built UE4SS 2. When debugging a crash, checkout that exact commit 3. Rebuild to generate matching .pdb files 4. Then debug the minidump
Tips
Set WINEDEBUG=-all to reduce Wine’s debug output during builds (already done by build.sh) If you encounter “access denied” errors, ensure you have winbind or samba installed PDB files are generated in the same directory as the DLL files

Updating git submodules
If you want to update git submodules, you do so one of three ways:
1. You can execute git submodule update --init --recursive to update all submodules.
2. You can also choose to update submodules one by one, by executing git submodule update --init --recursive deps/<first-or-third>/<Repo> . Do not use the --remote option unless you actually want to update to the latest commit.

3. If you would rather pick a specific commit or branch to update a submodule to then cd into the submodule directory for that dependency and execute git checkout <branch name or commit> . The main dependency you might want to update from time to time is deps/first/Unreal .

Credits
All contributors since the project became open source: https://github.com/UE4SS-RE/RE-UE4SS/graphs/contributors
Original Creator The original creator no longer wishes to be involved in or connected to this project. Please respect their wishes, and avoid using their past usernames in connection with this project. Archengius
UHT compatible header generator CasualGamer
Injector code & aob scanner is heavily based on his work, 90% of that code is his. SunBeam Extra signature for function ‘GetFullName’ for UE4.25. Regex to check for proper signature format when loaded from ini. Lots and lots of work on signatures tomsa const char* to vector<int> converter
tomsa: Idea & most of the code Original Creator: Nibblet support boop / usize New UFunction hook method RussellJ Blueprint Modloader inspiration Narknon Certain features and maintenance/rehosting of the project DeadMor0z Certain features and Lua updates/maintenance OutTheShade Unreal Mappings (USMAP) Generator DmgVol Inspiration for map dumper Buckminsterfullerene Rewriting the documentation, various fixes

trumank Lua bindings generator, various fixes, automation & improvements
localcc C++ API

Thanks to everyone who helped with testing
GreenHouse Otis_Inf SunBeam Motoson hooter Synopis Buckminsterfullerene
Supported by

Blueprint Modloader

As our BP system is based on RussellJ’s, this tutorial video is applicable for creating a blueprint mod for UE4SS:

Unreal Mod Loader Tutorials: Creating A Blueprint
Russell.J

Ansehen auf

Live Viewer

The Live Viewer is a tool that allows you to search, view, edit & watch the properties of every loaded object making it very powerful for debugging mods or figuring out how values are changed during runtime.
In order to see it, you must make sure that the following configuration settings are set to 1:
GuiConsoleEnabled GuiConsoleVisible
live-viewer

## Dumpers

C++ Header Generator
The C++ dumper is a tool that generates C++ headers from UE4 classes and blueprints.
The keybind to generate headers is by default CTRL + H , and it can be changed in Mods/Keybinds/Scripts/main.lua .
It generates a .hpp file for each blueprint (including animation blueprint and widget blueprint), and then all of the base classes inside of <ProjectName>.hpp or <EngineModule>.hpp . All classes are at the top of the files, followed by all structs. Enums are seperated into files named the same as their class, but with _enums appended to the end.

Configurations
DumpOffsetsAndSizes (bool)
Whether to property offsets and sizes Default: 1
KeepMemoryLayout (bool)
Whether memory layouts of classes and structs should be accurate This must be set to 1, if you want to use the generated headers in an actual C++ project When set to 0, padding member variables will not be generated Default: 0
Warning: A value of 1 has no purpose yet as memory value is not accurate either way!
LoadAllAssetsBeforeGeneratingCXXHeaders (bool)
Whether to force all assets to be loaded before generating headers

## Default: 0

Warning: Can require multiple gigabytes of extra memory, is not stable & will crash the game if you load past the main menu after dumping

Unreal Header Tool (UHT) Dumper
Generates Unreal Header Tool compatible C++ headers for creating a mirror .uproject for your game. The guide for using these headers can be found here.
The keybind to generate headers is by default CTRL + Numpad 9 , and it can be changed in Mods/Keybinds/Scripts/main.lua .

Configurations
IgnoreAllCoreEngineModules (bool) Whether to skip generating packages that belong to the engine, particularly useful for any games that make alterations to the engine Default: 0
IgnoreEngineAndCoreUObject (bool) Whether to skip generating the Engine and CoreUObject packages Default: 1
MakeAllFunctionsBlueprintCallable (bool) Whether to force all UFUNCTION macros to have
BlueprintCallable
Default: 1
Warning: This will cause some errors in the generated headers that you will need to manually fix
MakeAllPropertyBlueprintsReadWrite (bool)

Whether to force all UPROPERTY macros to have
BlueprintReadWrite
Also forces all UPROPERTY macros to have meta=
(AllowPrivateAccess=true)
Default: 1
MakeEnumClassesBlueprintType (bool)
Whether to force UENUM macros on enums to have BlueprintType if the underlying type was implicit or uint8 Default: 1
Warning: This also forces the underlying type to be uint8 where the type would otherwise be implicit
MakeAllConfigsEngineConfig (bool)
Whether to force Config = Engine on all UCLASS macros that use either one of: DefaultConfig , GlobalUserConfig or
ProjectUserConfig
Default: 1

Object Dumper
Dumps all loaded objects to the file UE4SS_ObjectDump.txt (you can turn on force loading for all assets).
The keybind to dump objects is by default CTRL + J , and can be changed in Mods/Keybinds/Scripts/main.lua .
Example output:

[000002A70F57E5C0] Function /Game/UI/Art/WidgetParts/Basic_ButtonScalable2.Basic_ButtonScal able2_C:BndEvt__Button_0_K2Node_ComponentBoundEvent_0_OnButtonC lickedEvent__DelegateSignature [n: 5343AA] [c: 000002A727993A00] [or: 000002A708466980] [000002A70F57E4E0] Function /Game/UI/Art/WidgetParts/Basic_ButtonScalable2.Basic_ButtonScal able2_C:PreConstruct [n: 4057B] [c: 000002A727993A00] [or: 000002A708466980] [000002A70F876600] BoolProperty /Game/UI/Art/WidgetParts/Basic_ButtonScalable2.Basic_ButtonScal able2_C:PreConstruct:IsDesignTime [o: 0] [n: 4D63DB] [c: 00007FF683722CC0] [owr: 000002A70F57E4E0]

There are multiple sets of opening & closing square brackets and each set has a different meaning and the letters in this table explains what they mean. Within the first set of brackets is the location in memory where the object or property is stored.

Letters n c or o owr kp vp mc df
pc
ic ss em

Meaning
Name of an object/property Class of the object/property/enum value Outer of the object Offset of a property value in an object Owner of an FField, 4.25+ only Key property of an FMapProperty Value property of an FMapProperty Class that this FClassProperty refers to Function that this FDelegateProperty refers to Class that this FObjectProperty/FFieldPathProperty refers to Class that this FInterfaceProperty refers to Struct that this FStructProperty refers to Enum that this FEnumProperty refers to

UE Member Variable
NamePrivate ClassPrivate OuterPrivate Offset_Internal Owner KeyProp ValueProp MetaClass
FunctionSignatu
PropertyClass
InterfaceClass
Struct
Enum

Letters

fm

bm

v sps ai

Meaning
Field mask that this FBoolProperty refers to Byte mask that this FBoolProperty refers to Value corresponding to this enum key SuperStruct of this UClass Property that this FArrayProperty

UE Member Variable
FieldMask
ByteMask
N/A SuperStruct Inner

Configurations
LoadAllAssetsBeforeDumpingObjects (bool) Whether to force all assets to be loaded before dumping objects Default: 0
Warning: Can require multiple gigabytes of extra memory, is not stable & will crash the game if you load past the main menu after dumping

.usmap Dumper
Generate .usmap mapping files for unversioned properties. The keybind to dump mappings is by default Ctrl + Numpad 6 , and can be changed in Mods/Keybinds/Scripts/main.lua . Thanks to OutTheShade for the original implementation.

.umap Recreation Dumper



Dump all loaded actors to the file ue4ss_static_mesh_data.csv to generate .umaps in-editor.

Two prerequisites are required to load the dumped actors in-editor to reconstruct the .umap :

All dumped actors (static meshes, their materials/textures) must be reconstructed in the editor Download zMapGenBP.zip from the Releases page and follow the instructions in the Readme file inside of it

The keybind to dump mappings is by default Ctrl + Numpad 7 , and can be changed in Mods/Keybinds/Scripts/main.lua .

Universal UE Mods

WIP

Experimental
WIP

## Installation

Core structure concept
There are four concepts you need to know about.
1. The root directory . This directory contains the UE4SS dll file.
2. The working directory . This directory contains configuration and mod files and is located inside the root directory .
3. The game directory . This directory usually contains a small executable with the name of your game and a folder with the same name. This executable is not your actual game but instead it’s just a small wrapper that starts any 3rd party launcher such as Steam or if there is none then it launches the real executable. Example of a game directory : D:\Games\Epic
Games\SatisfactoryEarlyAccess\
4. The game executable directory . This directory contains the real executable file for your game and is not part of the UE4SS directory structure. You can also recognize it as the game executable located there is usually the largest (much larger than the wrapper above) and is the one running as the child process of the wrapper when the game is running. Example of a game executable directory : D:\Games\Epic
Games\SatisfactoryEarlyAccess\FactoryGame\Binaries\Win64 \
Choosing an installation method
You can install UE4SS in a couple of different ways.
The goal is to have the *.dll of UE4SS to be loaded by the target game one way or another, and have the configuration files and \Mods\ directory in the correct place for UE4SS to find them.

## Method #1 - Basic Install

Using method #1 will mean that the root directory and working directory are treated as one single directory that happens to also be the same directory as your game executable directory .

The basic install is intended for end-users who are using UE4SS for mods that use it and don’t need to do any development work. There should be no extra windows visible when using this method.
The preferred and most straightforward way to install UE4SS is to choose the UE4SS_v{version_number} download (e.g. UE4SS_v3.0.0 ) and then just drag & drop all the necessary files into the game executable directory .
Now all you need to do is start your game and UE4SS will automatically be injected.

Method #2 - Developer Install
Using method #2 will mean that the root directory and working directory are treated as one single directory that happens to also be the same directory as your game executable directory .
The developer install is intended for mod developers or users who wish to use UE4SS for debugging, dumping or other utilities. The difference between this version and the basic install version is that there are some extra files included, and slightly different default settings in the UE4SSsettings.ini file, such as the console and GUI console being visible.
The preferred and most straightforward way to install UE4SS is to choose the zDEV-UE4SS_v{version_number} download (e.g. zDEV-UE4SS_v3.0.0 ) and then just drag & drop all the necessary files into the game executable directory .
Now all you need to do is start your game and UE4SS will automatically be injected.

## Expirimental Install

If you want the latest and greatest features and don’t mind the potential for more bugs than the main release, you can visit the experimental part of releases which is automatically updated for each commit to the main branch.
There are a lot of older files in the experimental releases, so you will need to look for the latest downloads. You can tell which are the latest by looking at the date of the release.
There are two main packages you need to look for: basic, and dev. They are in a similar formats as above, but with -commit number-commit hash appended to the end of the version number. For example, a basic install might look like UE4SS_v3.0.0-5-ga5e818e.zip and a dev install might look like zDEV-UE4SS_v3.0.0-5-ga5e818e.zip .

Note: If you are using the experimental version for development, you should be using the dev version of the docs, which you can get to by appending docs.ue4ss.com with /dev (e.g. this page would be https://docs.ue4ss.com/dev/installation-guide ).

Manual Injection
Using manual injection will mean that the root directory and working directory are treated as one single directory that happens to also be the same directory as your game executable directory , but any directory may be used.
Following the download of basic or dev methods (stable or experimental) and delete dwmapi.dll . Afterwards, launch the game and manually inject UE4SS.dll using your injector of choice.

Central Install Location
This method is a way to install UE4SS in one place for all your games. Simply extract the zip file of your choice (basic or dev) in any directory

outside the game directory , this is what’s known as the root directory .

You will then create a folder inside with the name of your game and drag UE4SS-settings.ini in to it, this is what’s known as the working directory .

If the path to your game executable is

D:\Games\Epic Games\SatisfactoryEarlyAccess\FactoryGame\Binaries\Win64\Factor yGame-Win64-Shipping.exe

Then the name of your working directory should be SatisfactoryEarlyAccess . This directory will be automatically found and used by UE4SS if it exists.
As of UE4SS 3.0 (basic install), the following files & folders exist inside the working directory :
Mods Mod folders mods.txt
UE4SS-settings.ini UE4SS.log UE4SS.dll dwmapi.dll (Can have a name of any DLL that is loaded by the game engine or by its dependencies)
Now all you need to do is start your game and point your injector of choice to <root directory>/UE4SS.dll .
If you use this method, if you keep a copy of UE4SS-settings.ini inside the root directory then this file will act as a default for all the games that don’t have a working directory as long as you still point your injector to the root directory .
This way you can use this method for most of your games and at the same time you can use method #1 or method #2 for other games.

How to verify that UE4SS is running successfully?
Try any of the following:

Press any of the default keyboard shortcuts, such as @ or F10 that open the in-game console (using built-in ConsoleEnablerMod ) Check that the log file UE4SS.log is created in the same folder as the UE4SS main DLL, and that the log file contains fresh timestamps and no errors. Enable the GUI console in UE4SS-settings.ini and check that it appears as a separate window (rendered with OpenGL by default). (For developers, if the game is confirmed to be safely debuggable) Check that the UE4SS library is being loaded in a debugger and has its threads spawned in the target game’s process and in a reasonable state.

Custom Game Configs

IMPORTANT: Some of these files may be out of date as the games/UE4SS updates. If you find that a game’s custom game config is out of date, please open an issue on the UE4SS-RE/RE-UE4SS repository. Make sure that you first test if the game works without the custom game config, as it may have been fixed in the latest version of UE4SS.

These settings are for games that have altered the engine in ways that make UE4SS not work out of the box.
You need to download the files from each folder for your game and place them in the same folder in your UE4SS installation. For example, downloading the configs for Kingdom Hearts 3 should result in your files being in the following structure:

Binaries/Win64/

├── CustomGameConfigs/

│ └── Kingdom Hearts 3/

│

├── UE4SS_Signatures/

│

│ ├── FName_Constructor.lua

│

│ ├── FName_ToString.lua

│

│ ├── StaticConstructObject.lua

│

├── MemberVariableLayout.ini

│

├── UE4SS-settings.ini

│

├── VTableLayout.ini

… but obviously the file structure will change depending on the game’s configs.
If you download the zDEV version, all these files are already included in the zip file.
You can find them here

Lua API

These are the Lua API functions available in UE4SS, on top of the standard libraries that Lua comes with by defualt.
For version: 3.0.0.
Current status: incomplete.

Full API Overview
This is an overall list of API definitions available in UE4SS. For more readable information, see the individual API definition pages in the collapsible sections 4.1, 4.2 and 4.3.
Warning: This API list is not updated as often as the individual API definition pages. It may be out of date.

Table Definitions
The definitions appear as: FieldName | FieldValueType Fields that only have numeric field names have ‘#’ as their name in this definition for clarity All fields are required unless otherwise specified

ModifierKeys # | string (Microsoft Virtual Key-Code)

PropertyTypes ObjectProperty ObjectPtrProperty Int8Property Int16Property IntProperty Int64Property NameProperty FloatProperty StrProperty ByteProperty UInt16Property UIntProperty UInt64Property BoolProperty ArrayProperty MapProperty StructProperty ClassProperty WeakObjectProperty EnumProperty TextProperty

| internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value | internal_value

OffsetInternalInfo

Property

| string (Name of the property to use

as relative start instead of base)

RelativeOffset | integer (Offset from relative start

to this property)

ArrayPropertyInfo Type | table (PropertyTypes)

CustomPropertyInfo

Name

| string (Name to use with the __index

metamethod)

Type

| table (PropertyTypes)

BelongsToClass | string (Full class name without type

that this property belongs to)

OffsetInternal | integer or table (if table:

OffsetInternalInfo, otherwise: offset from base to this

property)

ArrayProperty | table (Optional, ArrayPropertyInfo)

EObjectFlags

- A table of object flags that can be or'd together by

using |.

RF_NoFlags

| 0x00000000

RF_Public

| 0x00000001

RF_Standalone

| 0x00000002

RF_MarkAsNative

| 0x00000004

RF_Transactional

| 0x00000008

RF_ClassDefaultObject

| 0x00000010

RF_ArchetypeObject

| 0x00000020

RF_Transient

| 0x00000040

RF_MarkAsRootSet RF_TagGarbageTemp RF_NeedInitialization RF_NeedLoad RF_KeepForCooker RF_NeedPostLoad RF_NeedPostLoadSubobjects RF_NewerVersionExists RF_BeginDestroyed RF_FinishDestroyed RF_BeingRegenerated RF_DefaultSubObject RF_WasLoaded RF_TextExportTransient RF_LoadCompleted RF_InheritableComponentTemplate RF_DuplicateTransient RF_StrongRefOnFrame RF_NonPIEDuplicateTransient RF_Dynamic RF_WillBeLoaded RF_HasExternalPackage RF_AllFlags

| 0x00000080 | 0x00000100 | 0x00000200 | 0x00000400 | 0x00000800 | 0x00001000 | 0x00002000 | 0x00004000 | 0x00008000 | 0x00010000 | 0x00020000 | 0x00040000 | 0x00080000 | 0x00100000 | 0x00200000 | 0x00400000 | 0x00800000 | 0x01000000 | 0x01000000 | 0x02000000 | 0x04000000 | 0x08000000 | 0x0FFFFFFF

EInternalObjectFlags

- A table of internal object flags that can be or'd

together by using |.

ReachableInCluster

| 0x00800000

ClusterRoot

| 0x01000000

Native

| 0x02000000

Async

| 0x04000000

AsyncLoading

| 0x08000000

Unreachable

| 0x10000000

PendingKill

| 0x20000000

RootSet

| 0x40000000

GarbageCollectionKeepFlags

| 0x0E000000

AllFlags

| 0x7F800000

## Delayed Action System (game-thread timers)

MANUAL SUPPLEMENT, not from the source PDF. The published docs predate it; sourced from
RE-UE4SS PR #1128 and verified live in this build (see `G1R/UE4SS-Lua-Best-Practices.md`).
These run the callback ON the game thread, so they need no nested `ExecuteInGameThread` and
avoid the `LoopAsync` + `ExecuteInGameThread` reentrancy bug (issue #1180). Per the PR:
"Mod creators should avoid using `ExecuteAsync` and `LoopAsync` in favor of the new system
when possible." Route periodic and delayed work through `kit.async`, which prefers these and
falls back to the async variants only where a build lacks them.

ExecuteInGameThreadWithDelay(integer DelayMs, function Callback) -> handle
- Runs Callback once on the game thread after DelayMs. Returns a cancellable handle.
LoopInGameThreadWithDelay(integer DelayMs, function Callback) -> handle
- Runs Callback on the game thread every DelayMs until cancelled. Returns a cancellable handle.
ExecuteInGameThreadAfterFrames(integer Frames, function Callback) -> handle
- Like ExecuteInGameThreadWithDelay but the delay is counted in rendered frames.
LoopInGameThreadAfterFrames(integer Frames, function Callback) -> handle
- Like LoopInGameThreadWithDelay but the interval is counted in frames.
RetriggerableExecuteInGameThreadWithDelay(handle Handle, integer DelayMs, function Callback)
- Re-arms an existing delayed action, mirroring UE's Delay node (a fresh call resets the timer).
CancelDelayedAction(handle Handle)
- Cancels a pending delayed action by its handle (only one created by the same mod).

The system also exposes pause / unpause / query operations on a handle (per PR #1128); confirm
their exact names against the RE-UE4SS source before relying on them, they are not used here.

## Global Functions

print(string Message) - Does not have the capability to format. Use
'string.format' if you require formatting.
StaticFindObject(string ObjectName) -> { UObject | AActor | nil }
StaticFindObject(UClass Class=nil, UObject InOuter=nil, string ObjectName, bool ExactClass=false)
- Maps to https://docs.unrealengine.com/4.26/enUS/API/Runtime/CoreUObject/UObject/StaticFindObject/
FindFirstOf(string ShortClassName) -> { UObject | AActor | nil }
- Find the first non-default instance of the supplied class name
- Param 'ShortClassName': Should only contains the class name itself without path info
FindAllOf(string ShortClassName) -> table -> { UObject | AActor } | nil
- Find all non-default instances of the supplied class name
- Param 'ShortClassName': Should only contains the class name itself without path info
RegisterKeyBind(integer Key, function Callback) RegisterKeyBind(integer Key, table ModifierKeys, function callback)
- Registers a callback for a key-bind - Callbacks can only be triggered while the game or debug console is on focus
IsKeyBindRegistered(integer Key) IsKeyBindRegistered(integer Key, table ModifierKeys)
- Checks if, at the time of the invocation, the supplied keys have been registered
RegisterHook(string UFunctionName, function Callback) -> integer, integer
- Registers a callback for a UFunction - Callbacks are triggered when a UFunction is executed - The callback params are: UObject self, UFunctionParams... - Returns two ids, both of which must be passed to 'UnregisterHook' if you want to unregister the hook.
UnregisterHook(string UFunctionName, integer PreId, integer PostId)
- Unregisters a hook.
ExecuteInGameThread(function Callback) - Execute code inside the game thread using
ProcessEvent. - Will execute as soon as the game has time to execute.

FName(string Name) -> FName FName(integer ComparisonIndex) -> FName
- Returns the FName for this string/ComparisonIndex or the FName for "None" if the name doesn't exist

FText(string Text) -> FText - Returns the FText representation of this string

StaticConstructObject(UClass Class, UObject Outer, FName Name, #Optional EObjectFlags Flags, #Optional EInternalObjectFlags
InternalSetFlags, #Optional bool CopyTransientsFromClassDefaults,
#Optional bool AssumeTemplateIsArchetype,
#Optional UObject Template, #Optional FObjectInstancingGraph InstanceGraph,
#Optional UPackage ExternalPackage, #Optional void SubobjectOverrides #Optional) ->
UObject - Attempts to construct a UObject of the passed UClass - (>=4.26) Maps to
https://docs.unrealengine.com/4.27/enUS/API/Runtime/CoreUObject/UObject/StaticConstructObject_Intern al/1/
- (<4.25) Maps to https://docs.unrealengine.com/4.27/enUS/API/Runtime/CoreUObject/UObject/StaticConstructObject_Intern al/2/

RegisterCustomProperty(table CustomPropertyInfo) - Registers a custom property to be used automatically
with 'UObject.__index'

ForEachUObject(function Callback) - Execute the callback function for each UObject in
GUObjectArray - The callback params are: UObject object, integer
ChunkIndex, integer ObjectIndex

NotifyOnNewObject(string UClassName, function Callback) - Executes the provided Lua function whenever an
instance of the provided class is constructed. - Inheritance is taken into account, so if you provide
"/Script/Engine.Actor" as the class then it will execute your - Lua function when any object is constructed that's
either an AActor or is derived from AActor.

RegisterCustomEvent(string EventName, function Callback) - Registers a callback that will get called when a BP
function/event is called with the name 'EventName'.

RegisterLoadMapPreHook(function Callback) - Registers a callback that will get called before

UEngine::LoadMap is called. - The callback params are: UEngine Engine, struct
FWorldContext& WorldContext, FURL URL, class UPendingNetGame* PendingGame, FString& Error
- Params (except strings & bools & FOutputDevice) must be retrieved via 'Param:Get()' and set via 'Param:Set()'.

RegisterLoadMapPostHook(function Callback) - Registers a callback that will get called after
UEngine::LoadMap is called. - The callback params are: UEngine Enigne, struct
FWorldContext& WorldContext, FURL URL, class UPendingNetGame* PendingGame, FString& Error
- Params (except strings & bools & FOutputDevice) must be retrieved via 'Param:Get()' and set via 'Param:Set()'.

RegisterInitGameStatePreHook(function Callback) - Registers a callback that will get called before
AGameModeBase::InitGameState is called. - The callback params are: AGameModeBase Context - Params (except strings & bools & FOutputDevice) must
be retrieved via 'Param:Get()' and set via 'Param:Set()'.

RegisterInitGameStatePostHook(function Callback) - Registers a callback that will get called after
AGameModeBase::InitGameState is called. - The callback params are: AGameModeBase Context - Params (except strings & bools & FOutputDevice) must
be retrieved via 'Param:Get()' and set via 'Param:Set()'.

RegisterBeginPlayPreHook(function Callback) - Registers a callback that will get called before
AActor::BeginPlay is called. - The callback params are: AActor Context - Params (except strings & bools & FOutputDevice) must
be retrieved via 'Param:Get()' and set via 'Param:Set()'.

RegisterBeginPlayPostHook(function Callback) - Registers a callback that will get called after
AActor::BeginPlay is called. - The callback params are: AActor Context - Params (except strings & bools & FOutputDevice) must
be retrieved via 'Param:Get()' and set via 'Param:Set()'.

RegisterProcessConsoleExecPreHook(function Callback) - Registers a callback that will get called before
UObject::ProcessConsoleExec is called. - The callback params are: UObject Context, string Cmd,
table CommandParts, FOutputDevice Ar, UObject Executor - Params (except strings & bools & FOutputDevice) must
be retrieved via 'Param:Get()' and set via 'Param:Set()'. - If the callback returns nothing (or nil), the
original return value of ProcessConsoleExec will be used. - If the callback returns true or false, the supplied
value will override the original return value of ProcessConsoleExec.

RegisterProcessConsoleExecPostHook(function Callback)

- Registers a callback that will get called after UObject::ProcessConsoleExec is called.
- The callback params are: UObject Context, string Cmd, table CommandParts, FOutputDevice Ar, UObject Executor
- Params (except strings & bools & FOutputDevice) must be retrieved via 'Param:Get()' and set via 'Param:Set()'.
- If the callback returns nothing (or nil), the original return value of ProcessConsoleExec will be used.
- If the callback returns true or false, the supplied value will override the original return value of ProcessConsoleExec.

RegisterCallFunctionByNameWithArgumentsPreHook(function Callback)
- Registers a callback that will be called before UObject::CallFunctionByNameWithArguments is called.
- The callback params are: UObject Context, string Str, FOutputDevice Ar, UObject Executor, bool bForceCallWithNonExec
- Params (except strings & bools & FOutputDevice) must be retrieved via 'Param:Get()' and set via 'Param:Set()'.
- If the callback returns nothing (or nil), the original return value of CallFunctionByNameWithArguments will be used.
- If the callback returns true or false, the supplied value will override the original return value of CallFunctionByNameWithArguments.

RegisterCallFunctionByNameWithArgumentsPostHook(function Callback)
- Registers a callback that will be called after UObject::CallFunctionByNameWithArguments is called.
- The callback params are: UObject Context, string Str, FOutputDevice Ar, UObject Executor, bool bForceCallWithNonExec
- Params (except strings & bools & FOutputDevice) must be retrieved via 'Param:Get()' and set via 'Param:Set()'.
- If the callback returns nothing (or nil), the original return value of CallFunctionByNameWithArguments will be used.
- If the callback returns true or false, the supplied value will override the original return value of CallFunctionByNameWithArguments.

RegisterULocalPlayerExecPreHook(function Callback) - Registers a callback that will be called before
ULocalPlayer::Exec is called. - The callback params are: ULocalPlayer Context, UWorld
InWorld, string Cmd, FOutputDevice Ar - Params (except strings & bools & FOutputDevice) must
be retrieved via 'Param:Get()' and set via 'Param:Set()'. - The callback can have two return values. - If the first return value is nothing (or nil), the
original return value of Exec will be used. - If the first return value is true or false, the
supplied value will override the original return value of Exec. - The second return value controls whether the original
Exec will execute. - If the second return value is nil or true, the
orginal Exec will execute.

- If the second return value is false, the original Exec will not execute.

RegisterULocalPlayerExecPostHook(function Callback) - Registers a callback that will be called after
ULocalPlayer::Exec is called. - The callback params are: ULocalPlayer Context, UWorld
InWorld, string Cmd, FOutputDevice Ar - Params (except strings & bools & FOutputDevice) must
be retrieved via 'Param:Get()' and set via 'Param:Set()'. - The callback can have two return values. - If the first return value is nothing (or nil), the
original return value of Exec will be used. - If the first return value is true or false, the
supplied value will override the original return value of Exec. - The second return value controls whether the original
Exec will execute. - If the second return value is nil or true, the
orginal Exec will execute. - If the second return value is false, the original
Exec will not execute.

RegisterConsoleCommandHandler(string CommandName, function Callback)
- Registers a callback for a custom console commands. - The callback only runs in the context of UGameViewportClient. - The callback params are: string Cmd, table CommandParts, FOutputDevice Ar - Params (except strings & bools & FOutputDevice) must be retrieved via 'Param:Get()' and set via 'Param:Set()'. - The callback must return either true or false. - If the callback returns true, no further handlers will be called for this command.

RegisterConsoleCommandGlobalHandler(string CommandName, function Callback)
- Registers a callback for a custom console command. - Unlike 'RegisterConsoleCommandHandler', this global variant runs the callback for all contexts. - The callback params are: string Cmd, table CommandParts, FOutputDevice Ar - Params (except strings & bools & FOutputDevice) must be retrieved via 'Param:Get()' and set via 'Param:Set()'. - The callback must return either true or false. - If the callback returns true, no further handlers will be called for this command.

ExecuteAsync(function Callback) - Asynchronously executes the specified function

ExecuteWithDelay(integer DelayInMilliseconds, function Callback)
- Asynchronously executes the specified function after the specified delay

RegisterConsoleCommandHandler(string CommandName, function Callback)

- Executes the provided Lua function whenever the CommandName is entered into the UE console.
- The parameters for the callback are the full command (string),
- and the parameters (table, containing the full command split by spaces), and FOutputDevice.
- In the callback, return true to prevent other handlers from handling the command, or false to allow other handlers.

LoadAsset(string AssetPathAndName) - Loads an asset by name. - Must only be called from within the game thread. - For example, from within a UFunction hook or
RegisterConsoleCommandHandler callback.

FindObject(string|FName|nil ClassName, string|FName|nil ObjectShortName, EObjectFlags RequiredFlags, EObjectFlags BannedFlags) -> UObject derivative
- Finds an object by either class name or short object name.
- ClassName or ObjectShortName can be nil, but not both.
- Returns a UObject of a derivative of UObject.

FindObject(UClass InClass, UObject InOuter, string Name, bool ExactClass)
- Finds an object. Works the same way as the function by the same name in the UE source.

FindObjects(integer NumObjectsToFind, string|FName|nil ClassName, string|FName|nil ObjectShortName, EObjectFlags RequiredFlags, EObjectFlags BannedFlags, bool bExactClass) -> table -> { UObject derivative }
- Finds the first specified number of objects by class name or short object name.
- To find all objects that match your criteria, set NumObjectsToFind to 0 or nil.
- Returns a table of UObject derivatives

LoopAsync(integer DelayInMilliseconds, function Callback) - Starts a loop that sleeps for the supplied number of
milliseconds and stops when the callback returns true.

IterateGameDirectories() -> table - Returns a table of all game directories. - An example of an absolute path to Win64:
Q:\SteamLibrary\steamapps\common\Deep Rock Galactic\FSD\Binaries\Win64
- To get to the same directory, do: IterateGameDirectories().Game.Binaries.Win64
- Note that the game name is replaced by 'Game' to keep things generic.
- You can use '.__name' and '.__absolute_path' to retrieve values.
- You can use '.__files' to retrieve a table containing all files in this directory.

files.

- You also use '.__name' and '.__absolute_path' for

## Classes

RemoteObject Inheritance: - The first of two base objects that all other objects
inherits from - Contains a pointer to a C/C++ object that's typically
owned by the game Methods IsValid() -> bool - Returns whether this object is valid or not
LocalObject Inheritance: - The second of two base objects that all other objects
inherits from - Contains an inlined object which is fully owned by
Lua Methods
UnrealVersion Inheritance: Methods GetMajor() -> integer GetMinor() -> integer IsEqual(number MajorVersion, number MinorVersion) -
> bool IsAtLeast(number MajorVersion, number MinorVersion)
-> bool IsAtMost(number MajorVersion, number MinorVersion)
-> bool IsBelow(number MajorVersion, number MinorVersion) -
> bool IsAbove(number MajorVersion, number MinorVersion) -
> bool
UE4SS Inheritance: - Class for interacting with UE4SS metadata Methods GetVersion() -> 3x integer - Returns major, minor and hotfix version
numbers - To detect version 1.0 or below, check if
"UE4SS" or "UE4SS.GetVersion" is nil
Mod Inheritance: RemoteObject - Class for interacting with the local mod object Methods SetSharedVariable(string VariableName, any Value) - Sets a variable that can be accessed by any
mod. - The second parameter (Value) can only be one
of the following types: nil, string, number, bool, UObject(+derivatives), lightuserdata.
- These variables do not get reset when hot-

reloading.

GetSharedVariable(string VariableName) -> any - Gets a variable that could've been set from
another mod. - The return value can only be one of the
following types: nil, string, number, bool, UObject(+derivatives), lightuserdata.

type() -> string - Returns "ModRef"

UObject Inheritance: RemoteObject - This is the base class that most other Unreal Engine
game objects inherit from Methods __index(string MemberVariableName) -> auto - Attempts to return either a member variable
or a callable UFunction - Can return any type, you can use the 'type()'
function on the returned value to figure out what Lua class it's using (if non-trivial type)

NewValue) variable

__newindex(string MemberVariableName, auto - Attempts to set the value of a member

GetFullName() -> string - Returns the full name & path info for a
UObject & its derivatives

GetFName() -> FName - Returns the FName of this object by copy - All FNames returned by '__index' are returned
by reference

GetAddress() -> integer - Returns the memory address of this object

GetClass() -> UClass - Returns the class of this object, this is
equivalent to 'UObject->ClassPrivate' in Unreal

GetOuter() -> UObject - Returns the Outer of this object

IsAnyClass() -> bool - Returns true if this UObject is a UClass or a
derivative of UClass

Reflection() -> UObjectReflection - Returns a reflection object

GetPropertyValue(string MemberVariableName) -> auto - Identical to __index

NewValue)

SetPropertyValue(string MemberVariableName auto
- Identical to __newindex

IsClass() -> bool - Returns whether this object is a UClass or
UClass derivative

GetWorld() -> UWorld - Returns the UWorld that this UObject is
contained within.

CallFunction(UFunction function, auto Params...) - Calls the supplied UFunction on this UObject.

IsA(UClass Class) -> bool IsA(string FullClassName) -> bool
- Returns whether this object is of the specified class.

HasAllFlags(EObjectFlags FlagsToCheck) - Returns whether the object has all of the
specified flags.

HasAnyFlags(EObjectFlags FlagsToCheck) - Returns whether the object has any of the
specified flags.

HasAnyInternalFlags(EInternalObjectFlags InternalFlagsToCheck)
- Return whether the object has any of the specified internal flags.

ProcessConsoleExec(string Cmd, nil Reserved, UObject Executor)
- Calls UObject::ProcessConsoleExec with the supplied params.

UE4SS Unreal

type() -> string - Returns the type of this object as known by
- This does not return the type as known by

UStruct Inheritance: UObject Methods GetSuperStruct() -> UClass - Returns the SuperStruct of this struct (can
be invalid).

struct. Function. iterating.

ForEachFunction(function Callback) - Iterates every UFunction that belongs to this
- The callback has one param: UFunction
- Return true in the callback to stop

struct. Property. iterating.

ForEachProperty(function Callback) - Iterates every Property that belongs to this
- The callback has one param: Property
- Return true in the callback to stop

UClass Inheritance: UClass Methods GetCDO() -> UClass - Returns the ClassDefaultObject of a UClass.

IsChildOf(UClass Class) -> bool - Returns whether or not the class is a child
of another class.

AActor Inheritance: UObject Methods GetWorld() -> UObject | nil - Returns the UWorld that this actor belongs to

GetLevel() -> UObject | nil - Returns the ULevel that this actor belongs to

FName Inheritance: LocalObject Methods ToString() -> string - Returns the string for this FName

GetComparisonIndex() -> integer - Returns the ComparisonIndex for this FName
(index into global names array)

TArray Inheritance: RemoteObject Methods __index(integer ArrayIndex) - Attempts to retrieve the value at the
specified offset in the array - Can return any type, you can use the 'type()'
function on the returned value to figure out what Lua class it's using (if non-trivial type)

__newindex(integer ArrayIndex, auto NewValue) - Attempts to set the value at the specified
offset in the array

GetArrayAddress() -> integer - Returns the address in memory where the
TArray struct is located

GetArrayNum() -> integer - Returns the number of current elements in the

array

GetArrayMax() -> integer - Returns the maximum number of elements
allowed in this array (aka capacity)

GetArrayDataAddress -> integer - Returns the address in memory where the data
for this array is stored

ForEach(function Callback) - Iterates the entire TArray and calls the
callback function for each element in the array - The callback params are: integer index,
RemoteUnrealParam | LocalUnrealParam elem - Use 'elem:get()' and 'elem:set()' to
access/mutate an array element

UEnum Inheritance: RemoteObject Methods GetNameByValue(integer Value) -> FName - Returns the FName that corresponds to the
specified value. ForEachName(LuaFunction Callback) -> FName - Iterates every FName/Value combination that
belongs to this enum. - The callback has two params: FName Name,
integer Value. - Return true in the callback to stop
iterating.

RemoteUnrealParam | LocalUnrealParam Inheritance: RemoteObject | LocalObject - This is a dynamic wrapper for any and all types &
classes - Whether the Remote or Local variant is used
depends on the requirements of the data but the usage is identical with either param types
Methods get() -> auto - Returns the underlying value for this param

set(auto NewValue) - Sets the underlying value for this param

type() -> string - Returns "RemoteUnrealParam" or
"LocalUnrealParam"

UScriptStruct Inheritance: LocalObject Methods __index(string StructMemberVarName) -> auto - Attempts to return the value for the supplied
variable - Can return any type, you can use the 'type()'
function on the returned value to figure out what Lua class

it's using (if non-trivial type)

NewValue) variable

__newindex(string StructMemberVarName, auto - Attempts to set the value for the supplied

GetBaseAddress() -> integer - Returns the address in memory where the
UObject that this UScriptStruct belongs to is located

GetStructAddress() -> integer - Returns the address in memory where this
UScriptStruct is located

GetPropertyAddress() -> integer - Returns the address in memory where the
corresponding U/FProperty is located

IsValid() -> bool - Returns whether the struct is valid

IsMappedToObject() -> bool - Returns whether the base object is valid

IsMappedToProperty() -> bool - Returns whether the property is valid

type() -> string - Returns "UScriptStruct"

UFunction Inheritance: UObject Methods __call(UFunctionParams...) - Attempts to call the UFunction

GetFunctionFlags() -> integer - Returns the flags for the UFunction.

SetFunctionFlags(integer Flags) Sets the flags for the UFuction.

FString Inheritance: RemoteObject - A TArray of characters Methods ToString() - Returns a string that Lua can understand

Clear() - Clears the string by setting the number of
elements in the TArray to 0

FieldClass Inheritance: LocalObject Methods GetFName()

- Returns the FName of this class by copy.

Property Inheritance: RemoteObject Methods GetFullName() -> string - Returns the full name & path for this
property.

GetFName() -> FName - Returns the FName of this property by copy. - All FNames returned by '__index' are returned
by reference.

IsA(PropertyTypes PropertyType) -> bool - Returns true if the property is of type
PropertyType.

GetClass() -> PropertyClass

ContainerPtrToValuePtr(UObjectDerivative Container, integer ArrayIndex) -> LightUserdata
- Equivalent to FProperty::ContainerPtrToValuePtr<uint8> in UE.

ImportText(string Buffer, LightUserdata Data, integer PortFlags, UObject OwnerObject)
- Equivalent to FProperty::ImportText in UE, except without the 'ErrorText' param.

ObjectProperty Inheritance: Property Methods GetPropertyClass() -> UClass - Returns the class that this property holds.

BoolProperty Inheritance: Property Methods GetByteMask() -> integer GetByteOffset() -> integer GetFieldMask() -> integer GetFieldSize() -> integer

StructProperty Inheritance: Property Methods GetStruct() -> UScriptStruct - Returns the UScriptStruct that's mapped to
this property.

ArrayProperty Inheritance: Property Methods GetInner() -> Property - Returns the inner property of the array.

UObjectReflection

Inheritance: Methods
GetProperty(string PropertyName) -> Property - Returns a property meta-data object

FOutputDevice Inheritance: RemoteObject Methods Log(string Message) - Logs a message to the output device (i.e: the
in-game console)

FWeakObjectPtr Inheritance: LocalObject Methods Get() -> UObjectDerivative - Returns the pointed to UObject or UObject
derivative (can be invalid, so call UObject:IsValid after calling Get).

Key

The Key table contains Microsoft virtual key-code strings.
This table is automatically populated with data. Do not modify the data inside this table.

Key-code strings
LEFT_MOUSE_BUTTON RIGHT_MOUSE_BUTTON CANCEL MIDDLE_MOUSE_BUTTON XBUTTON_ONE XBUTTON_TWO BACKSPACE TAB CLEAR RETURN PAUSE CAPS_LOCK IME_KANA IME_HANGUEL IME_HANGUL IME_ON IME_JUNJA IME_FINAL IME_HANJA IME_KANJI IME_OFF ESCAPE IME_CONVERT IME_NONCONVERT IME_ACCEPT IME_MODECHANGE SPACE PAGE_UP PAGE_DOWN END HOME LEFT_ARROW UP_ARROW RIGHT_ARROW DOWN_ARROW SELECT PRINT EXECUTE PRINT_SCREEN INS DEL HELP ZERO ONE TWO THREE FOUR FIVE SIX SEVEN EIGHT NINE A B

C D E F G H I J K L M N O P Q R S T U V W X Y Z LEFT_WIN RIGHT_WIN APPS SLEEP NUM_ZERO NUM_ONE NUM_TWO NUM_THREE NUM_FOUR NUM_FIVE NUM_SIX NUM_SEVEN NUM_EIGHT NUM_NINE MULTIPLY ADD SEPARATOR SUBTRACT DECIMAL DIVIDE F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 F13 F14

F15 F16 F17 F18 F19 F20 F21 F22 F23 F24 NUM_LOCK SCROLL_LOCK BROWSER_BACK BROWSER_FORWARD BROWSER_REFRESH BROWSER_STOP BROWSER_SEARCH BROWSER_FAVORITES BROWSER_HOME VOLUME_MUTE VOLUME_DOWN VOLUME_UP MEDIA_NEXT_TRACK MEDIA_PREV_TRACK MEDIA_STOP MEDIA_PLAY_PAUSE LAUNCH_MAIL LAUNCH_MEDIA_SELECT LAUNCH_APP1 LAUNCH_APP2 OEM_ONE OEM_PLUS OEM_COMMA OEM_MINUS OEM_PERIOD OEM_TWO OEM_THREE OEM_FOUR OEM_FIVE OEM_SIX OEM_SEVEN OEM_EIGHT OEM_102 IME_PROCESS PACKET ATTN CRSEL EXSEL EREOF PLAY ZOOM PA1 OEM_CLEAR

## Example

local enter_key = Key.RETURN

ModifierKey

The ModifierKey table contains Microsoft virtual key-code strings that are meant to be modifier keys such as CONTROL and ALT .
This table is automatically populated with data. Do not modify the data inside this table.

Modifier key-code strings
SHIFT CONTROL ALT

Example
local CTRL_Key = ModifierKey.CONTROL

PropertyTypes

The PropertyTypes table contains type information for Unreal Engine properties. This is primarily used with the RegisterCustomProperty Lua function.
This table is automatically populated with data. Do not modify the data inside this table.

Structure
Key ObjectProperty Int8Property Int16Property IntProperty Int64Property NameProperty FloatProperty StrProperty ByteProperty BoolProperty ArrayProperty MapProperty StructProperty ClassProperty WeakObjectProperty EnumProperty TextProperty

Value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value internal_value

Example
local PropertyType = PropertyTypes.ObjectProperty

OffsetInternalInfo

The OffsetInternalInfo table contains information related to a custom property.
You must supply data yourself when using this table.

Structure
Key Property RelativeOffset

Value Type string
integer

Information
Name of the property to use as relative start instead of base Offset from relative start to this property

Example
local PropertyInfo = { ["Property"] = "HistoryBuffer", ["RelativeOffset"] = 0x10
}

ArrayPropertyInfo

The ArrayPropertyInfo table contains type information for custom ArrayProperty properties.
You must supply data yourself when using this table.

Structure
Key Type

Value Type table

Sub Type PropertyTypes

Example
local ArrayPropertyInfo = { ["Type"] = PropertyTypes.IntProperty
}

CustomPropertyInfo

The CustomPropertyInfo table contains information about a custom property.
You must supply data yourself when using this table.

Structure
Key Name Type BelongsToClass
OffsetInternal
ArrayProperty


Value Type
string
table
string
integer or table
table

Sub Type PropertyTypes OffsetInternalInfo ArrayPropertyInfo

Inform
Name to use w __index metam
Full class nam that this prope
Sub Type only table
Only use when PropertyTypes


Simple Example
Creates a custom property with the name MySimpleCustomProperty that accesses whatever data is at offset 0xF40 in any instance of class Character as if it was an IntProperty .
local CustomPropertyInfo = { ["Name"] = "MySimpleCustomProperty", ["Type"] = PropertyTypes.IntProperty, ["BelongsToClass"] = "/Script/Engine.Character" ["OffsetInternal"] = 0xF40
}

## Advanced Example

Creates a custom property with the name MyAdvancedCustomProperty that accesses whatever data is at offset 0xF48 in any instance of class Character as if it was an ArrayProperty with an inner type of IntProperty .

local CustomPropertyInfo = { ["Name"] = "MyAdvancedCustomProperty", ["Type"] = PropertyTypes.ArrayProperty, ["BelongsToClass"] = "/Script/Engine.Character" ["OffsetInternal"] = 0xF48, ["ArrayProperty"] = { ["Type"] = PropertyTypes.IntProperty }
}

EObjectFlags

A table of object flags that can be or’d together by using |

Field Name RF_NoFlags RF_Public RF_Standalone RF_MarkAsNative RF_Transactional RF_ClassDefaultObject RF_ArchetypeObject RF_Transient RF_MarkAsRootSet RF_TagGarbageTemp RF_NeedInitialization RF_NeedLoad RF_KeepForCooker RF_NeedPostLoad RF_NeedPostLoadSubobjects RF_NewerVersionExists RF_BeginDestroyed RF_FinishDestroyed RF_BeingRegenerated RF_DefaultSubObject RF_WasLoaded RF_TextExportTransient RF_LoadCompleted RF_InheritableComponentTemplate RF_DuplicateTransient RF_StrongRefOnFrame RF_NonPIEDuplicateTransient RF_Dynamic RF_WillBeLoaded RF_HasExternalPackage

Field Value Type 0x00000000 0x00000001 0x00000002 0x00000004 0x00000008 0x00000010 0x00000020 0x00000040 0x00000080 0x00000100 0x00000200 0x00000400 0x00000800 0x00001000 0x00002000 0x00004000 0x00008000 0x00010000 0x00020000 0x00040000 0x00080000 0x00100000 0x00200000 0x00400000 0x00800000 0x01000000 0x01000000 0x02000000 0x04000000 0x08000000

## Field Name RF_AllFlags

Field Value Type 0x0FFFFFFF

EInternalObjectFlags

A table of internal object flags that can be or’d together by using |

Field Name ReachableInCluster ClusterRoot Native Async AsyncLoading Unreachable PendingKill RootSet GarbageCollectionKeepFlags AllFlags

Field Value Type 0x00800000 0x01000000 0x02000000 0x04000000 0x08000000 0x10000000 0x20000000 0x40000000 0x0E000000 0x7F800000

EFindName

Field Name FNAME_Find FNAME_Add

Field Value Type 0 1

RemoteObject

The RemoteObject class is the first of two base objects that all other objects inherits from, the other one being LocalObject.
It contains a pointer to a C++ object that is typically owned by the game.

Inheritance
None

Methods
IsValid()
Return type: bool Returns: whether this object is valid or not
Example
-- 'StaticFindObject' returns a UObject which inherits from RemoteObject. local Object = StaticFindObject("/Script/CoreUObject.Object") if Object:IsValid() then
print("Object is valid\n") else
print("Object is NOT valid\n") end

LocalObject

The LocalObject class is the second of two base objects that all other objects inherits from, the other one being RemoteObject.
It contains an inlined C++ object that is owned by Lua.

Inheritance
None

Methods
None

UnrealVersion

The UnrealVersion class contains helper functions for retrieving which version of Unreal Engine that is being used.

Inheritance
None

Methods
GetMajor()
Return type: integer
GetMinor()
Return type: integer
IsEqual(number MajorVersion, number MinorVersion)
Return type: bool
IsAtLeast(number MajorVersion, number MinorVersion)
Return type: bool
IsAtMost(number MajorVersion, number MinorVersion)
Return type: bool

IsBelow(number MajorVersion, number MinorVersion)

Return type: bool

IsAbove(number MajorVersion, number MinorVersion)
Return type: bool

Examples
local Major = UnrealVersion.GetMajor() local Minor = UnrealVersion.GetMinor() print(string.format("Version: %s.%s\n", Major, Minor))
if UnrealVersion.IsEqual(5, 0) then print("Version is 5.0\n") end if UnrealVersion.IsAtLeast(5, 0) then print("Version is >=5.0\n") end if UnrealVersion.IsAtMost(5, 0) then print("Version is <=5.0\n") end if UnrealVersion.IsBelow(5, 0) then print("Version is <5.0\n") end if UnrealVersion.IsAbove(5, 0) then print("Version is >5.0\n") end

UE4SS

The UE4SS class is for interacting with UE4SS metadata.

Inheritance
None

Methods

GetVersion()

Returns: the current version of UE4SS that is being used. Return Value:

#

Type

Information

1

integer

Major version

2

integer

Minor version

3

integer

Hotfix version

Example #1

Warning: This only works in UE4SS 1.1+. See example #2 for UE4SS <=1.0.

local Major, Minor, Hotfix = UE4SS.GetVersion() print(string.format("UE4SS v%d.%d.%d\n", Major, Minor, Hotfix))
Example #2 This example shows how to distinguish between UE4SS <=1.0, which didn’t have the UE4SS class, and UE4SS >=1.1.
if UE4SS == nil then print("Running UE4SS <=1.0\n")
end

Mod

The Mod class is responsible for interacting with the local mod object.

Inheritance
RemoteObject

Methods
SetSharedVariable(string VariableName, any Value)
Sets a variable that can be accessed by any mod. The second parameter Value can only be one of the following types: nil , string , number , bool , UObject (+derivatives), lightuserdata .
Warning: These variables do not get reset when hot-reloading.
Example
-- When sharing a UObject, make absolutely sure that it's a UObject that doesn't cease to exist before it's used again. -- It's a very bad idea to share transient objects like actors as they might die and stop existing. local StaticObject = StaticFindObject("/Script/Engine.Default__GameplayStatics") -- The 'ModRef' variable is a global variable that's automatically created and is the instance of the current mod. ModRef:SetSharedVariable("MyVariable", StaticObject)
GetSharedVariable(string VariableName)
Return type: any Returns: a variable that could’ve been set from another mod.

The return value can only be one of the following types: nil , string , number , bool , UObject (+derivatives), lightuserdata .

Example

-- Assuming that the example script for 'SetSharedVariable' has been executed. local SharedObject = ModRef:GetSharedVariable("MyVariable")
-- 'GetSharedVariable' may return anything that its able to store. -- Any mod is able to override the value for any shared variable. if SharedObject and type(SharedObject) == "userdata" and SharedObject:type() == "UObject" and SharedObject:IsValid() then
print(string.format("SharedObject '%s' is valid.\n", SharedObject:GetFullName())) else
print("SharedObject was nil, not userdata, not a UObject, or an invalid UObject") end

type()
Return type: string Returns: “ModRef”

UObject

The UObject class is the base class that most other Unreal Engine game objects inherit from.

Inheritance
RemoteObject

Metamethods

__index

Usage: UObject["ObjectMemberName"] or
UObject.ObjectMemberName
Returns either a member variable (reflected property or custom property) or a UFunction.
This method can return any type, and you can use the UObjectspecific type() function on the returned value to figure out the type if the type is non-trivial.
If the type is trivial, use the regular type() Lua function.

Return Value:

#

Type

1

UObject or UFunction

Information
If the type is UObject , then the actual type may be any class that inherits from UObject .

Example:

local Character = FindFirstOf("Character")
-- Retrieve a non-trivial type local MovementComponent = Character.CharacterMovement
-- Retrieve a trivial type local JumpMaxCount = Character.JumpMaxCount
-- Call a UFunction member on the object -- Remember to use a colon (:) for calls local CanCharacterJump = Character:CanJump()

__newindex
Usage: UObject["ObjectMemberName"] = NewValue or
UObject.ObjectMemberName = NewValue
Sets the value of a member variable to NewValue .
Example: Sets the value of MaxParticleResize in the first instance of class UEngine in memory.
local Engine = FindFirstOf("Engine") Engine.MaxParticleResize = 4

Methods

GetFullName()

Returns: the full name & path info for a UObject & its derivatives Return Value:

#

Type

Information

1

string

Full name and path of the UObject

Example:

local Engine = FindFirstOf("Engine") print(string.format("Engine Name: %s", Engine:GetFullName()))
-- Output -- Engine Name: FGGameEngine /Engine/Transient.FGGameEngine_2147482618

GetFName()
Returns: the FName of the UObject. This is equivalent to Object>NamePrivate in Unreal.

Warning: All FNames returned by __index are returned by reference.

Return Value:

#

Type

1

FName

Example:

Information FName of the UObject

local Character = FindFirstOf("Character") if Character:IsValid() then
local CharacterName = Character:GetFName() print(string.format("ComparisonIndex: 0x%X\n", CharacterName:GetComparisonIndex())) end

GetAddress()

Returns: where in memory the UObject is located. Return Value:

#

Type

Information

1

integer

64-bit integer, address of the UObject

Example:

local Character = FindFirstOf("Character") if Character:IsValid() then
print(string.format("Character: 0x%X\n", Character:GetAddress())) end

GetClass()

Returns: the class of this object. This is equivalent to UObject>ClassPrivate in Unreal.
Return Value:

#

Type

Information

1

UClass

The class of the UObject

Example:

local Character = FindFirstOf("Character") if Character:IsValid() then
print(string.format("Character Class: 0x%X\n", Character:GetClass():GetAddress())) end

GetOuter()

Returns: the outer of the UObject. This is equivalent to Object>OuterPrivate in Unreal.

Return Value:

#

Type

Information

1

UObject

The outer UObject of this UObject

Example:

local Character = FindFirstOf("Character") if Character:IsValid() then
print(string.format("Character Outer: 0x%X\n", Character:GetOuter():GetAddress())) end

IsAnyClass()

Return type: bool Returns: true if this UObject is a UClass or a derivative of UClass

Reflection()
Return type: UObjectReflection Returns: a reflection object

GetPropertyValue(string MemberVariableName)
Return type: auto Identical to __index metamethod (doing UObject["ObjectMemberName"] )

SetPropertyValue(string MemberVariableName, auto NewValue)
Identical to __newindex metamethod (doing UObject["ObjectMemberName"] = NewValue )

IsClass()
Return type: bool Returns: whether this object is a UClass or UClass derivative

GetWorld()
Return type: UWorld Returns: the UWorld that this UObject is contained within.

IsA(UClass Class)
Return type: bool Returns: whether this object is of the specified UClass .

IsA(string FullClassName)

Return type: bool Returns: whether this object is of the specified class name.

HasAllFlags(EObjectFlags FlagsToCheck)
Return type: bool Returns: whether the object has all of the specified flags.

HasAnyFlags(EObjectFlags FlagsToCheck)
Return type: bool Returns: whether the object has any of the specified flags.

HasAnyInternalFlags(EInternalObjectFlags InternalFlagsToCheck)
Return type: bool Returns: whether the object has any of the specified internal flags.

CallFunction(UFunction Function, auto Params…)
Calls the supplied UFunction on this UObject .

ProcessConsoleExec(string Cmd, nil Reserved, UObject Executor)
Calls UObject::ProcessConsoleExec with the supplied params.

type()
Return type: string Returns: the type of this object as known by UE4SS This does not return the type as known by Unreal Not equivalent to doing type(UObject) , which returns the type as known by Lua (a ‘userdata’)

## UStruct

Inheritance
UObject

Methods
GetSuperStruct()
Return type: UClass Returns: the SuperStruct of this struct (can be invalid).

ForEachFunction(function Callback)
Iterates every UFunction that belongs to this struct. The callback has one param: UFunction Function . Return true in the callback to stop iterating.

ForEachProperty(function Callback)
Iterates every Property that belongs to this struct. The callback has one param: Property Property . Return true in the callback to stop iterating.

## UScriptStruct

Inheritance
LocalObject
Metamethods
__index
Usage: UScriptStruct["StructMemberName"] or
UScriptStruct.StructMemberName
Return type: auto Returns the value for the supplied member name. Can return any type, you can use the type() function on the returned value to figure out what Lua class it’s using (if non-trivial type). Example:
local scriptStruct = FindFirstOf('_UI_Items_C') -- Either of the following can be used: local item = scriptStruct['Item'] local item = scriptStruct.Item
__newindex
Usage: UScriptStruct["StructMemberName"] = NewValue or
UScriptStruct.StructMemberName = NewValue
Attempts to set the value for the supplied member name to NewValue . Example:

local scriptStruct = FindFirstOf('_UI_Items_C')

-- Either of the following can be used: scriptStruct['Item'] = 5 scriptStruct.Item = 5

Methods
GetBaseAddress()
Return type: integer Returns: the address in memory where the UObject that this UScriptStruct belongs to is located
GetStructAddress()
Return type: integer Returns: the address in memory where this UScriptStruct is located
GetPropertyAddress()
Return type: integer Returns: the address in memory where the corresponding UProperty / FProperty is located
IsValid()
Return type: bool Returns: whether the struct is valid
IsMappedToObject()
Return type: bool Returns: whether the base object is valid

IsMappedToProperty()

Return type: bool Returns: whether the property is valid

type()
Return type: string Returns: “UScriptStruct”

## UClass

Inheritance
UStruct

Methods
GetCDO()
Return type: UClass Returns: the ClassDefaultObject of a UClass .

IsChildOf(UClass Class)
Return type: bool Returns: whether or not the class is a child of another class.

## UFunction

Inheritance
UObject

Metamethods
__call
Usage: UFunction(UFunctionParams...) Return type: auto Attempts to call the UFunction and returns the result, if any. If the UFunction is obtained without a context (e.g. from StaticFindObject ), a UObject context must be passed as the first parameter.
Methods
GetFunctionFlags()
Return type: integer Returns: the flags for the UFunction .
SetFunctionFlags(integer Flags)
Sets the flags for the UFunction .

## UEnum

Inheritance
RemoteObject

Methods
GetNameByValue(integer Value)
Return type: FName Returns: the FName that corresponds to the specified value.
ForEachName(LuaFunction Callback)
Iterates every FName / Value combination that belongs to this enum. The callback has two params: FName Name , integer Value . Return true in the callback to stop iterating.
GetEnumNameByIndex(integer Index)
Return types: FName , Integer Returns: the FName that coresponds the given Index . Returns: the Integer value that coresponds the given Index .
InsertIntoNames(string Name, integer Value, integer Index, boolean ShiftValues = true)
Inserts a FName / Value combination into a a UEnum at the given Index . If ShiftValues = true , will shift all enum values greater than inserted value by one.

EditNameAt(integer Index, string NewName)

At a given Index , will modify the found element in the UEnum and replace its Name with the given NewName .

EditValueAt(integer Index, integer NewValue)
At a given Index , will modify the found element in the UEnum and replace its value with the given NewValue .

RemoveFromNamesAt(integer Index, integer Count = 1, boolean AllowShrinking = true)
Will remove Count element(s) at the given Index from a UEnum . If AllowShrinkning = true , will shrink the enum array when removing elements.

## AActor

Inheritance
UObject

Methods
GetWorld()
Return types: UObject | nil Returns: the UWorld that this actor belongs to
GetLevel()
Return type: UObject | nil Returns: the ULevel that this actor belongs to

FString

FString is a TArray of characters.

Inheritance
RemoteObject

Methods
ToString()
Return type: string Returns: a string that Lua can understand.
Clear()
Clears the string by setting the number of elements in the TArray to 0.

## FName

Inheritance
LocalObject

Methods
ToString()
Return type: string Returns: the string for this FName .
GetComparisonIndex()
Return type: integer Returns: the ComparisonIndex for this FName (index into global names array).

## FText

Inheritance
LocalObject

Methods
ToString()
Return type: string Returns: the string representation of this FText .

## FieldClass

Inheritance
LocalObject

Methods
GetFName()
Return type: FName Returns: the FName of this class by copy.

## TArray

Inheritance
RemoteObject
Metamethods
__index
Usage: TArray[ArrayIndex] Return type: auto Attempts to retrieve the value at the specified integer offset ArrayIndex in the array. Can return any type, you can use the type() function on the returned value to figure out what Lua class it’s using (if non-trivial type).
__newindex
Usage: TArray[ArrayIndex] = NewValue Attempts to set the value at the specified integer offset ArrayIndex in the array to NewValue .
__len
Usage: #TArray Return type: integer Returns the number of current elements in the array.

## Methods

GetArrayAddress()
Return type: integer Returns: the address in memory where the TArray struct is located.

GetArrayNum()
Return type: integer Returns: the number of current elements in the array.

GetArrayMax()
Return type: integer Returns: the maximum number of elements allowed in this array (aka capacity).

GetArrayDataAddress()
Return type: integer Returns: the address in memory where the data for this array is stored.

Empty()
Clears the array.

ForEach(function Callback)
Iterates the entire TArray and calls the callback function for each element in the array. The callback params are: integer index , RemoteUnrealParam elem | LocalUnrealParam elem . Use elem:get() and elem:set() to access/mutate an array element.

RemoteUnrealParam

This is a dynamic wrapper for any and all types & classes.

Whether the Remote or Local variant is used depends on the requirements of the data but the usage is identical with either param types.

Inheritance
RemoteObject
Methods
get()
Return type: auto Returns: the underlying value for this param.
set(auto NewValue)
Sets the underlying value for this param.
type()
Return type: string Returns: “RemoteUnrealParam”.

LocalUnrealParam

This is a dynamic wrapper for any and all types & classes.

Whether the Remote or Local variant is used depends on the requirements of the data but the usage is identical with either param types.

Inheritance
LocalObject
Methods
get()
Return type: auto Returns: the underlying value for this param.
set(auto NewValue)
Sets the underlying value for this param.
type()
Return type: string Returns: “LocalUnrealParam”.

## Property

Inheritance
RemoteObject

Methods
GetFullName()
Return type: string Returns: the full name & path for this property.
GetFName()
Return type: FName Returns: the FName of this property by copy.
All FNames returned by __index are returned by reference.

IsA(PropertyTypes PropertyType)
Return type: bool Returns: true if the property is of type PropertyType .
GetClass()
Return type: PropertyClass
ContainerPtrToValuePtr(UObjectDerivative Container, integer ArrayIndex)
Return type: LightUserdata

Equivalent to FProperty::ContainerPtrToValuePtr<uint8> in UE.

ImportText(string Buffer, LightUserdata Data, integer PortFlags, UObject OwnerObject)
Equivalent to FProperty::ImportText in UE, except without the ErrorText param.

ObjectProperty

Inheritance
Property

Methods
GetPropertyClass()
Return type: UClass Returns: the class that this property holds.

StructProperty

Inheritance
Property

Methods
GetStruct()
Return type: UScriptStruct Returns: the UScriptStruct that’s mapped to this property.

## BoolProperty

Inheritance
Property

Methods
GetByteMask()
Return type: integer
GetByteOffset()
Return type: integer
GetFieldMask()
Return type: integer
GetFieldSize()
Return type: integer

## ArrayProperty

Inheritance
Property

Methods
GetInner()
Return type: Property Returns: the inner property of the array.

UObjectReflection

Inheritance
None

Methods
GetProperty(string PropertyName)
Return type: Property Returns: a property meta-data object.

FOutputDevice

Inheritance
RemoteObject

Methods
Log(string Message)
Logs a message to the output device (i.e: the in-game console).

FWeakObjectPtr

Inheritance
LocalObject

Methods
Get()
Return type: UObjectDerivative Returns: the pointed to UObject or UObject derivative.
The return can be invalid, so call UObject:IsValid after calling this function.

print

The print function is used for debugging and outputs a string to the debug console.
This function cannot be used to format strings, please use string.format for string formatting purposes.

New lines are not automatically appended so make sure to use \n whenever you want a new line.

Parameters
# 1

Type string

Information String to output

Example
print("Hello Debug Console\n")

FName

The FName function is used to get an FName representation of a string or integer .

Parameters (overload #1)

This overload mimics FName::FName with the FindType param set to EFindName::FName_Add .

#

Type

Information

1

string

String that you’d like to get an FName representation of

Finding or adding name type. It can be

2

EFindName

either FNAME_Find or FNAME_Add . Default is

FNAME_Add if not explicitly supplied

Parameters (overload #2)

#

Type

Information

1

integer

64-bit integer representing the ComparisonIndex part that you’d like to get an FName representation of

Finding or adding name type. It can be

2

EFindName

either FNAME_Find or FNAME_Add . Default is

FNAME_Add if not explicitly supplied

Return Value

#

Type

Information

FName corresponding to the string or

1

FName

ComparisonIndex , if one exists, or the “None” FName if one doesn’t exist. If FNAME_Add is

supplied then it adds the name if it doesn’t exist

local name = FName("MyName") print(name) -- MyName

FText

The FText function is used to get an FText representation of a string .
Useful when you have to interact with UserWidget -related classes for the UI of your mods, and call their SetText(FText("My New Text")) methods.

Parameters (overload #1)

This overload mimics FText::FText( FString&& InSourceString ).

#

Type

Information

1

string

String that you’d like to get an FText representation of

Return Value

#

Type

Information

1

FText

FText representation of incoming string

Example
local some_text = FText("MyText") print(some_text) -- MyText

IterateGameDirectories

Returns a table of all game directories.
An example of an absolute path to Win64 :
Q:\SteamLibrary\steamapps\common\Deep Rock
Galactic\FSD\Binaries\Win64 .
To get to the same directory, do IterateGameDirectories().<Game Name>.Binaries.Win64 .
You can use .__name and .__absolute_path to retrieve values. You can use .__files to retrieve a table containing all files in this directory. You also use .__name and .__absolute_path for files.

Return Value

#

Type

1

table

Information The game directories table

Example
for _, GameDirectory in pairs(IterateGameDirectories()) do print(GameDirectory.__name) print(GameDirectory.__absolute_path)
end

FindObject

FindObject is a function that finds an object. Overload #1 finds by either class name or short object name. Overload #2 works the same way as FindObject in the UE source.

Parameters (overload #1)

#

Type

Information

1

string|FName|nil

The short name of the class of the object

2

string|FName|nil

The short name of the object itself

3

EObjectFlags

Any flags that the object cannot have. Uses | as a seperator

4

EObjectFlags

Any flags that the object must have. Uses | as a seperator

Param 1 or Param 2 can be nil, but not both.

Parameters (overload #2)

#

Type

Information

1

UClass

The class to find

2

UObject

The outer to look inside. If this is null then param 3 should start with a package name

3

string

The object path to search for an object, relative to param 2

4

bool

Whether to require an exact match with the UClass parameter

Return Value (overload #1 & #2)

#

Type

Information

1

UObject

The derivative of the UObject

Example (overload #1)
-- SceneComponent instance called TransformComponent0 local Object = FindObject("SceneComponent", "TransformComponent0")
-- FirstPersonCharacter_C instance called FirstPersonCharacter_C_0 local Object = FindObject("FirstPersonCharacter_C", "FirstPersonCharacter_C_0", EObjectFlags.RF_NoFlags, EObjectFlags.RF_ClassDefaultObject)

Example (overload #2)
local Object = FindObject(UClass, World, "Character", true)

FindObjects

Finds the first specified number of objects by class name or short object name.
To find all objects that match your criteria, set param 1 to 0 or nil .

Parameters

#

Type

1

integer

1

string|FName|nil

2

string|FName|nil

3

EObjectFlags

4

EObjectFlags

6

bool

Information
The number of objects to find
The short name of the class of the object
The short name of the object itself
Any flags that the object cannot have. Uses | as a seperator
Any flags that the object must have. Uses | as a seperator
Whether to require an exact match with the UClass parameter

Return Value

# Type Sub Type

1

table

UObject

Information The derivative of the UObject

Example
local Object = FindObjects(4, "SceneComponent", "TransformComponent0", EObjectFlags.RF_NoFlags, EObjectFlags.RF_ClassDefaultObject, true) for _, Object in pairs(Objects) do
-- Do something with Object end

StaticFindObject

The StaticFindObject function is used to find any object that inherits from UObject that currently exists in memory.
This function is the recommended way of retrieving non-instance objects such as objects of type UClass or UFunction.

Parameters (overload #1)

#

Type

Information

1

string

Full name of the object to find, without the type prefix

Parameters (overload #2)

The parameters for this overload mimics the StaticFindObject function from UE4. For more information see: Unreal Engine API -> StaticFindObject

#

Type

Information

1

UClass

The class of the object to find, can be nil.

2

UObject

The outer to look inside. All packages are searched if nil.

3

string

Name of the object to find

4

bool

Whether to require an exact match with the UClass parameter

Return Value (overload #1 & #2)

#

Type

1

UObject, UClass, or AActor

Information
Object is only valid if an instance was found

Example (overload #1)

local CharacterInstance = StaticFindObject("/Script/Engine.Character") if not CharacterInstance:IsValid() then
print("No instance of class 'Character' was found.") end

FindFirstOf

The FindFirstOf function will find the first non-default instance of the supplied class name.

This function cannot be used to find non-instances or default instances.

Parameters

#

Type

Information

1

string

Short name of the class to find an instance of

Return Value

#

Type

1

UObject, UClass, or AActor

Information
Object is only valid if an instance was found

Example
local CharacterInstance = FindFirstOf("Character") if not CharacterInstance:IsValid() then
print("No instance of class 'Character' was found.") end

FindAllOf

The FindAllOf function will find all non-default instances of the supplied class name.

This function cannot be used to find non-instances or default instances.

Parameters

#

Type

1

string

Information Short name of the class to find instances of

Return Value

#

Type

1

nil or table

Sub Type
UObject, UClass, or AActor

Information
nil if no instances were found, otherwise a numerically indexed table of all instances

Example
Outputs the name of all objects that inherit from the Actor class.
local ActorInstances = FindAllOf("Actor") if not ActorInstances then
print("No instances of 'Actor' were found\n") else
for Index, ActorInstance in pairs(ActorInstances) do print(string.format("[%d] %s\n", Index,
ActorInstance:GetFullName())) end
end

StaticConstructObject

The StaticConstructObject function attempts to construct a UE4 object of some type.
This function mimics the function StaticConstructObject_Internal.

Parameters (overload #1)

#

Type

Information

1

UClass

The class of the object to construct

2

UObject

The outer to construct the object inside

3

FName

Optional

4

integer

Optional, 64 bit integer

5

integer

Optional, 64 bit integer

6

bool

Optional

7

bool

Optional

8

UObject

Optional

9

integer

Optional, 64 bit integer

10

integer

Optional, 64 bit integer

11

integer

Optional, 64 bit integer

Parameters (overload #2)

#

Type

Information

1

UClass

The class of the object to construct

2

UObject

The outer to construct the object inside

3

integer

Optional, 64 bit integer representation (ComparisonIndex & Number) of an FName

4

integer

Optional, 64 bit integer

5

integer

Optional, 64 bit integer

6

bool

Optional

7

bool

Optional

8

UObject

Optional

# 9 10 11

Type integer integer integer

Information Optional, 64 bit integer Optional, 64 bit integer Optional, 64 bit integer

Return Value

#

Type

Information

1

UObject

Object is only valid if an object was successfully constructed

Example
This example constructs a UConsole object.
local Engine = FindFirstOf("Engine") local ConsoleClass = Engine.ConsoleClass local GameViewport = Engine.GameViewport
if not ConsoleClass:IsValid() or not GameViewport:IsValid() then
print("Was unable to construct UConsole because the console class didn't exist\n") else
local CreatedConsole = StaticConstructObject(ConsoleClass, GameViewport, 0, 0, 0, nil, false, false, nil)
if CreatedConsole:IsValid() then print(string.format("CreatedConsole: %s\n",
CreatedConsole:GetFullName())) else print("Was unable to construct UConsole\n") end
end

ForEachUObject

The ForEachUObject function iterates every UObject that currently exists in GUObjectArray .
The GUObjectArray UE4 variable is a large chunked array that contains UObjects.
The structure of this array has changed over the years and the ForEachUObject function is designed to work identically across all engine versions.

Parameters

#

Type

Information

1

function

Callback to execute for every UObject in GUObjectArray

Callback Parameters

#

Type

Information

1

UObject

The UObject

2

integer

The chunk index of the UObject

3

integer

The object index of the UObject

Example
-- Warning: This will take quite a while to finish executing due to all of the 'print' calls ForEachUObject(function(Object, ChunkIndex, ObjectIndex)
print(string.format("Chunk: %X | Object: %X | Name: %s\n", ChunkIndex, ObjectIndex, Object:GetFullName())) end)

NotifyOnNewObject

The NotifyOnNewObject function executes a callback whenever an instance of the supplied class is constructed via StaticConstructObject_Internal by UE4.
Inheritance is taken into account, so if you provide "/Script/Engine.Actor" as the class then it will execute the callback when any object is constructed that’s either an AActor or is derived from AActor .

The provided class must exist before this calling this function.

Parameters

#

Type

Information

1

string

Full name of the class to get instance construction notifications for, without the type prefix

2

function

The callback to execute when an instance of the supplied class is constructed

Return Value

#

Type

1

UObject

Information The constructed object

Example
NotifyOnNewObject("/Script/Engine.Actor", function(ConstructedObject)
print(string.format("Constructed: %s\n", ConstructedObject:GetFullName())) end)

## What NOT to do

Please don’t duplicate the NotifyOnNewObject call for the same class multiple times, as it could cause performance issues if multiple mods are doing it (which has been seen in the wild).
For example, this:

NotifyOnNewObject("/Script/Engine.PlayerController", function(PlayerController)
PlayerController.bShowMouseCursor = true end) NotifyOnNewObject("/Script/Engine.PlayerController", function(PlayerController)
PlayerController.bForceFeedbackEnabled = false end) NotifyOnNewObject("/Script/Engine.PlayerController", function(PlayerController)
PlayerController.InputYawScale = 2.5 end) NotifyOnNewObject("/Script/Engine.PlayerController", function(PlayerController)
PlayerController.InputPitchScale = -2.5 end) NotifyOnNewObject("/Script/Engine.PlayerController", function(PlayerController)
PlayerController.InputRollScale = 1.0 end)

should just be this:

NotifyOnNewObject("/Script/Engine.PlayerController", function(PlayerController)
PlayerController.bShowMouseCursor = true PlayerController.bForceFeedbackEnabled = false PlayerController.InputYawScale = 2.5 PlayerController.InputPitchScale = -2.5 PlayerController.InputRollScale = 1.0 end)

ExecuteWithDelay

The ExecuteWithDelay function asynchronously executes the supplied callback after the supplied delay is over.

Parameters

#

Type

Information

1

integer

Delay, in milliseconds, to wait before executing the supplied callback

2

function

The callback to execute after the supplied delay is over

Example
ExecuteWithDelay(2000, function() print("Executed asynchronously after a 2 second delay\n")
end)

ExecuteInGameThread

ExecuteInGameThread is a function that allows you to execute code using ProcessEvent .
It will execute as soon as the game has time to execute it.

Parameters

#

Type

1

function

Information Callback to execute when the game has time

Example
ExecuteInGameThread(function() print("Hello from the game thread!\n")
end)

ExecuteAsync

The ExecuteAsync function asynchronously executes the supplied callback.
It works in a similar manner to ExecuteWithDelay, except that there is no delay beyond the cost of registering the callback.

Parameters

#

Type

1

function

Information The callback to execute

Example
ExecuteAsync(function() print("Executed asynchronously\n")
end)

LoopAsync

Starts a loop that sleeps for the supplied number of milliseconds and stops when the callback returns true.

Parameters

#

Type

1

integer

2

function

Information The number of milliseconds to sleep The callback function

Example
LoopAsync(1000, function() print("Hello World!") return false -- Loops forever
end)

LoadAsset

The LoadAsset function loads an asset by name.

It must only be called from within the game thread. For example, from within a UFunction hook or RegisterConsoleCommandHandler callback.

Parameters

#

Type

1

string

Information Path and name of the asset

Example
RegisterConsoleCommandHandler("summon", function(FullCommand, Parameters)
if #Parameters < 1 then return false end
-- Parameters[1] example: /Game/LevelElements/Refinery/Pipeline/BP_Pipeline_Start
LoadAsset(Parameters[1])
return false end)

RegisterKeyBind

The RegisterKeyBind function is used to bind a key on the keyboard to a Lua function.

Callbacks registered with this function are only executed when either the game or the debug console is in focus.

Parameters (overload #1)

#

Type

1

table

Sub Type
Key

2

function

Information
Key to bind Callback to execute when the key is hit on the keyboard

Parameters (overload #2)

#

Type

Sub Type

Information

1

integer

Key to bind, use the ‘Key’ table

2

table

ModifierKeys

Modifier keys required alongside the ‘Key’ parameter

3

function

Callback to execute when the key is hit on the keyboard

Example (overload #1)
RegisterKeyBind(Key.O, function() print("Key 'O' hit.\n")
end)

Example (overload #2)

RegisterKeyBind(Key.O, {ModifierKey.CONTROL, ModifierKey.ALT}, function()
print("Key 'CTRL + ALT + O' hit.\n") end)

Advanced Example (overload #1)
This registers a key bind with a callback that does nothing unless there are no widgets currently open
local AnyWidgetsOpen = false
RegisterHook("/Script/UMG.UserWidget:Construct", function() AnyWidgetsOpen = true
end)
RegisterHook("/Script/UMG.UserWidget:Destruct", function() AnyWidgetsOpen = false
end)
RegisterKeyBind(Key.B, function() if AnyWidgetsOpen then return end print("Key 'B' hit, while no widgets are open.\n")
end)

IsKeyBindRegistered

The IsKeyBindRegistered checks if, at the time of the invocation, the supplied keys have been registered

Parameters (overload #1)

#

Type

Sub Type

1

integer

Key

Information Key to check

Parameters (overload #2)

#

Type

Sub Type

Information

1

integer

Key

Key to bind, use the ‘Key’ table

2

table

ModifierKeys

Modifier keys to check alongside the ‘Key’ parameter

RegisterHook

The RegisterHook registers a callback for a UFunction Callbacks are triggered when a UFunction is executed. The callback params are: UObject self , UFunctionParams.. . Returns two ids, both of which must be passed to UnregisterHook if you want to unregister the hook.

Any UFunction that you attempt to register with RegisterHook must already exist in memory when you register it.

Parameters

#

Type

Information

1

string

Full name of the UFunction to hook. Type prefix has no effect.

If UFunction path starts with /Script/ :

Callback to execute before the UFunction is

2

function

executed.

Otherwise: Callback to execute after the

UFunction is executed.

(optional)

If UFunction path starts with /Script/ :

3

function

Callback to execute after the UFunction is

executed

Otherwise: Param does nothing.

Return Values

#

Type

1

integer

2

integer

Information The PreId of the hook The PostId of the hook

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
print("PlayerController restarted\n") end)

UnregisterHook

The UnregisterHook unregisters a callback for a UFunction .

Parameters

#

Type

Information

1

string

Full name of the UFunction to hook. Type prefix has no effect.

2

integer

The PreId of the hook

3

integer

The PostId of the hook

Example
local preId, postId = RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
print("PlayerController restarted\n") end)
UnregisterHook("/Script/Engine.PlayerController:ClientRestart", preId, postId)

RegisterCustomProperty

The RegisterCustomProperty function is used to register custom properties for use just as if it were a reflected native or BP property.
This is an advanced function that’s used to add support for non-reflected properties in the __index metamethod in multiple metatables.

Parameters
# Type

Sub Type

1

table

CustomPropertyInfo

Information
A table containing all of the required information for registering a custom property

Example
Registers a custom property with the name MySimpleCustomProperty that accesses whatever data is at offset 0xF40 in any instance of class Character as if it was an IntProperty .
It then grabs that value of the first instance of the class Character as an example of how the system works.
RegisterCustomProperty({ ["Name"] = "MySimpleCustomProperty", ["Type"] = PropertyTypes.IntProperty, ["BelongsToClass"] = "/Script/Engine.Character" ["OffsetInternal"] = 0xF40
})
local CharacterInstance = FindFirstOf("Character") if CharacterInstance:IsValid() then
local MySimplePropertyValue = CharacterInstance.MySimpleCustomProperty end

RegisterCustomEvent

This registers a callback that will get called when a blueprint function or event is called with the name EventName .

Parameters

#

Type

1

string

2

function

Information Name of the event to hook. The callback to call when the event is called.

Example
RegisterCustomEvent("MyCustomEvent", function() print("MyCustomEvent was called\n")
end)

RegisterInitGameStatePreHook

This registers a callback that will get called before AGameModeBase::InitGameState is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

1

AGameStateBase

Information The game state context

Example
RegisterInitGameStatePreHook(function(GameState) print("InitGameStatePreHook")
end)

RegisterInitGameStatePostHook

This registers a callback that will get called after AGameModeBase::InitGameState is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

1

AGameStateBase

Information The game state context

Example
RegisterInitGameStatePostHook(function(GameState) print("InitGameStatePostHook")
end)

RegisterBeginPlayPreHook

This registers a callback that will get called before AActor::BeginPlay is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

Information

1

AActor

The actor context

Example
RegisterBeginPlayPreHook(function(Actor) print("BeginPlayPreHook")
end)

RegisterBeginPlayPostHook

This registers a callback that will get called after AActor::BeginPlay is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

Information

1

AActor

The actor context

Example
RegisterBeginPlayPostHook(function(Actor) print("BeginPlayPostHook")
end)

RegisterProcessConsoleExecPreHo ok

This registers a callback that will get called before UObject::ProcessConsoleExec is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .
If the callback returns nothing (or nil), the original return value of ProcessConsoleExec will be used.
If the callback returns true or false, the supplied value will override the original return value of ProcessConsoleExec .

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

Information

1

UObject

The object context

2

string

The command

3

string

The rest of the command

4

FOutputDevice

The AR

5

UObject

The executor

Callback Return Value

# Type

Information

1

bool

Whether to override the original return value of
ProcessConsoleExec

local function MyCallback(Context, Command, CommandParts, Ar, Executor)
-- Do something with the parameters -- Return nil to use the original return value of ProcessConsoleExec -- Return true or false to override the original return value of ProcessConsoleExec
return nil end
RegisterProcessConsoleExecPreHook(MyCallback)

RegisterProcessConsoleExecPostH ook

This registers a callback that will get called after UObject::ProcessConsoleExec is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .
If the callback returns nothing (or nil), the original return value of ProcessConsoleExec will be used.
If the callback returns true or false, the supplied value will override the original return value of ProcessConsoleExec .

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

Information

1

UObject

The object context

2

string

The command

3

string

The rest of the command

4

FOutputDevice

The AR

5

UObject

The executor

Callback Return Value

# Type

Information

1

bool

Whether to override the original return value of
ProcessConsoleExec

local function MyCallback(Context, Command, CommandParts, Ar, Executor)
-- Do something with the parameters -- Return nil to use the original return value of ProcessConsoleExec -- Return true or false to override the original return value of ProcessConsoleExec
return nil end
RegisterProcessConsoleExecPostHook(MyCallback)

RegisterCallFunctionByNameWith ArgumentsPreHook

This registers a callback that will get called before UObject::CallFunctionByNameWithArguments is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .
If the callback returns nothing (or nil), the original return value of CallFunctionByNameWithArguments will be used.
If the callback returns true or false, the supplied value will override the original return value of CallFunctionByNameWithArguments .

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

Information

1

UObject

The object context

2

string

The string

3

FOutputDevice

The AR

4

UObject

The executor

5

bool

The bForceCallWithNonExec value

Callback Return Value

# Type

Information

1

bool

Whether to override the original return value of
CallFunctionByNameWithArguments

local function MyCallback(Context, Str, Ar, Executor, bForceCallWithNonExec)
-- Do something with the parameters -- Return nil to use the original return value of CallFunctionByNameWithArguments -- Return true or false to override the original return value of CallFunctionByNameWithArguments
return nil end
RegisterCallFunctionByNameWithArgumentsPreHook(MyCallback)

RegisterCallFunctionByNameWith ArgumentsPostHook

This registers a callback that will get called after UObject::CallFunctionByNameWithArguments is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .
If the callback returns nothing (or nil), the original return value of CallFunctionByNameWithArguments will be used.
If the callback returns true or false, the supplied value will override the original return value of CallFunctionByNameWithArguments .

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

Information

1

UObject

The object context

2

string

The string

3

FOutputDevice

The AR

4

UObject

The executor

5

bool

The bForceCallWithNonExec value

Callback Return Value

# Type

Information

1

bool

Whether to override the original return value of
CallFunctionByNameWithArguments

local function MyCallback(Context, Str, Ar, Executor, bForceCallWithNonExec)
-- Do something with the parameters -- Return nil to use the original return value of CallFunctionByNameWithArguments -- Return true or false to override the original return value of CallFunctionByNameWithArguments
return nil end
RegisterCallFunctionByNameWithArgumentsPreHook(MyCallback)

RegisterULocalPlayerExecPreHook

This registers a callback that will get called before ULocalPlayer::Exec is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .
The callback can have two return values.
If the first return value is nothing (or nil), the original return value of Exec will be used. If the first return value is true or false, the supplied value will override the original return value of Exec. The second return value controls whether the original Exec will execute. If the second return value is nil or true, the orginal Exec will execute. If the second return value is false, the original Exec will not execute.

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

1

ULocalPlayer

2

UWorld

3

string

4

FOutputDevice

Information The local player context The world The command The AR

Callback Return Values

# Type

Information

1

bool

Whether to override the original return value of Exec

2

bool

Whether to execute the original Exec

Example
local function MyCallback(Context, InWorld, Command, Ar) -- Do something with the parameters -- Return true or false to override the original return
value of Exec -- Return false to prevent the original Exec from executing
return nil, true end
RegisterULocalPlayerExecPreHook(MyCallback)

RegisterULocalPlayerExecPostHoo k

This registers a callback that will get called after ULocalPlayer::Exec is called.
Parameters (except strings & bools & FOutputDevice ) must be retrieved via Param:Get() and set via Param:Set() .
The callback can have two return values.
If the first return value is nothing (or nil), the original return value of Exec will be used. If the first return value is true or false, the supplied value will override the original return value of Exec. The second return value controls whether the original Exec will execute. If the second return value is nil or true, the orginal Exec will execute. If the second return value is false, the original Exec will not execute.

Parameters

#

Type

1

function

Information The callback to register

Callback Parameters

#

Type

1

ULocalPlayer

2

UWorld

3

string

4

FOutputDevice

Information The local player context The world The command The AR

Callback Return Values

# Type

Information

1

bool

Whether to override the original return value of Exec

2

bool

Whether to execute the original Exec

Example
local function MyCallback(Context, InWorld, Command, Ar) -- Do something with the parameters -- Return true or false to override the original return
value of Exec -- Return false to prevent the original Exec from executing
return nil, true end
RegisterULocalPlayerExecPostHook(MyCallback)

RegisterConsoleCommandHandler

The RegisterConsoleCommandHandler function executes the provided Lua function whenever the supplied custom command is entered into the UE console.

Parameters

#

Type

Information

1

string

The name of the custom command

2

function

The callback to execute when the custom command is entered into the UE console

Callback Parameters

#

Type

Information

1

string

The name of the custom command

2

table

Table containing all parameters

3

FOutputDevice

The output device to write to

Callback Return Value

# Type

Information

1

bool

Whether to prevent other handlers from handling this command

RegisterConsoleCommandHandler("CommandExample", function(FullCommand, Parameters, OutputDevice)
print("Custom command callback for 'CommandExample' command executed.\n")
print(string.format("Full command: %s\n", FullCommand)) print(string.format("Number of parameters: %i\n", #Parameters))
for ParameterNumber, Parameter in pairs(Parameters) do print(string.format("Parameter #%i -> '%s'\n",
ParameterNumber, Parameter)) end
return true end)
-- Entered into console: CommandExample 1 2 3 -- Output --[[ Custom command callback for 'CommandExample' command executed. Full command: CommandExample 1 2 3 Number of parameters: 3 Parameter #1 -> '1' Parameter #2 -> '2' Parameter #3 -> '3' Parameter #0 -> 'CommandExample' --]]

RegisterConsoleCommandGlobalH andler

The RegisterConsoleCommandGlobalHandler function executes the provided Lua function whenever the supplied custom command is entered into the UE console.
Unlike RegisterConsoleCommandHandler , this global variant runs the callback for all contexts.

Parameters

#

Type

Information

1

string

The name of the custom command

2

function

The callback to execute when the custom command is entered into the UE console

Callback Parameters

#

Type

Information

1

string

The name of the custom command

2

table

Table containing all parameters

3

FOutputDevice

The output device to write to

Callback Return Value

# Type

Information

1

bool

Whether to prevent other handlers from handling this command

RegisterConsoleCommandGlobalHandler("CommandExample", function(FullCommand, Parameters, OutputDevice)
print("Custom command callback for 'CommandExample' command executed.\n")
print(string.format("Full command: %s\n", FullCommand)) print(string.format("Number of parameters: %i\n", #Parameters))
for ParameterNumber, Parameter in pairs(Parameters) do print(string.format("Parameter #%i -> '%s'\n",
ParameterNumber, Parameter)) end
return true end)
-- Entered into console: CommandExample 1 2 3 -- Output --[[ Custom command callback for 'CommandExample' command executed. Full command: CommandExample 1 2 3 Number of parameters: 3 Parameter #1 -> '1' Parameter #2 -> '2' Parameter #3 -> '3' Parameter #0 -> 'CommandExample' --]]

Examples

Check the code snippets at the bottom of the individual pages in the Lua API section and tutorials in this repository. Hogwarts Legacy modding uses UE4SS’ Lua API for its primary logic mods. This website contains example code for some of the mods.
You can search for interesting code in that page, the collapsed sections of the webpage will auto-expand when the text is found. The Palworld modding wiki has some decent docs and examples on how to develop Lua mods for new learners. Search GitHub for any Lua code calling reasonably uniquely-named UE4SS API functions, excluding the actual UE4SS repository from the search: https://github.com/search? q=language%3ALua+StaticFindObject+NOT+repo%3AUE4SSRE%2FRE-UE4SS&type=code https://github.com/search? q=language%3ALua+FindFirstOf+NOT+repo%3AUE4SSRE%2FRE-UE4SS&type=code and so on, as long as language:Lua is specified in the query

Creating a Lua mod

Before you start
To create a Lua mod in UE4SS, you should first:
know how to install UE4SS in your target game and make sure it is running OK; be able to write basic Lua code (see the official book Programming in Lua and its later editions, or any other recommended tutorial online); have an understanding of the object model of the Unreal Engine and the basics of game modding.

How does a minimal Lua mod look like
A Lua mod in UE4SS is a set of Lua scripts placed in a folder inside the Mods/ folder of UE4SS installation. Let’s call it MyLuaMod for the purpose of this example.
In order to be loaded and executed:
1. The mod folder must have a scripts subfolder and a main.lua file inside, so it looks like:
Mods\ ... MyLuaMod\ scripts\ main.lua ...
2. The Mods\MyLuaMod\scripts\main.lua file has some Lua code inside it, e.g.:
print("[MyLuaMod] Mod loaded\n")
3. The mod must be added and enabled in Mods\mods.txt with a new line containing the name of your mod folder (name of your mod) and 1 for enabling or 0 for disabling the mod:

... MyLuaMod : 1 ...

Your custom functionality goes inside main.lua , from which you can include other Lua files if needed, including creating your own Lua modules or importing various libraries.

What can you do in a Lua mod
The API provided by UE4SS and available to you in Lua is documented in sub-sections of chapter “Lua API” here. Using those functions and classes, you find and manipulate the instances of Unreal Engine objects in memory, creating new objects or modifying existing ones, calling their methods and accessing their fields.
Basically, you are doing the exact same thing that an Unreal Engine game developer does in their code, but using UE4SS to locate the necessary objects and guessing a bit, while the developers already knew where and what they are (because they have their source code).
Creating simple data types
If you need to create an object of a structure-like class, e.g. FVector , in order to pass it into a Unreal Engine function, UE4SS allows you to pass a Lua table with the fields of the class like {X=1.0, Y=2.0, Z=3.0} instead.
Using Lua C libraries
If you ever need to load Lua C libraries, that have native code (i.e. with DLLs on Windows), you can place these DLLs directly inside the same \scripts\ folder.
Setting up a Lua mod development environment
It is much easier to write mods if your code editor or IDE is properly configured for Lua development and knows about UE4SS API.

1. Configure your code editor/IDE to support Lua syntax highlighting and code completion. If you use VSCode, see here in Using Custom Lua Bindings.

2. Make sure that your build of UE4SS contains Mods\shared\Types.lua (a development build from Github releases contains it). This will load the UE4SS API definitions in your IDE.

3. (Optional) Dump the Lua Bindings fromm UE4SS Gui console, and follow the recommendations to load them here.

Then open the Mods/ folder of your UE4SS installation in your IDE, and create or modify your mod inside it.

Applying code changes

The main benefit of developing Lua mods is that you can quickly edit Lua sources without recompiling/rebuilding the C++ mod library as is always the case with C++ mods, and retry without restarting the game.
You can either:
reload all mods from the UE4SS GUI Console with the “Restart All Mods” button on the “Console” tab, or, enable “Hot reload” in UE4SS-settings.ini and use the assigned hotkey ( Ctrl+R by default) to do the same.

Your first mod
In the main.lua file of your mod, write some code that will try to access the objects of Unreal Engine inside your target game and do something that you can observe in the UE4SS console.
You can start by trying just

print("[MyLuaMod] Mod loaded\n")
and once you have verified that it runs OK, you can start implementing some actual functionality.
The example code below is fairly generic and should work for many games supported by UE4SS. It registers a hotkey Ctrl+F1 and when pressed, it reads the player coordinates and calculates how far the player has moved since the last

time the hotkey was pressed.

Note that the logging print calls include the name of the mod in square brackets, as it helps you find your mod’s output among other log strings in the console.

The player coordinates are retrieved in the following way:
1. Gets the player controller using UE4SS UEHelpers class. 2. Get the Pawn , which represents the actual “physical” entity that the
player can control in Unreal Engine. 3. Call the appropriate Unreal Engine method K2_GetActorLocation
that returns a Pawn ’s location (by accessing its parent Actor class). 4. The location is a 3-component vector of Unreal Engine type
FVector , having X , Y and Z as its fields.
local UEHelpers = require("UEHelpers")
print("[MyLuaMod] Mod loaded\n")
local lastLocation = nil
function ReadPlayerLocation() local FirstPlayerController =
UEHelpers:GetPlayerController() local Pawn = FirstPlayerController.Pawn local Location = Pawn:K2_GetActorLocation() print(string.format("[MyLuaMod] Player location: {X=%.3f,
Y=%.3f, Z=%.3f}\n", Location.X, Location.Y, Location.Z)) if lastLocation then print(string.format("[MyLuaMod] Player moved:
{delta_X=%.3f, delta_Y=%.3f, delta_Z=%.3f}\n", Location.X - lastLocation.X, Location.Y - lastLocation.Y, Location.Z - lastLocation.Z)
) end lastLocation = Location end
RegisterKeyBind(Key.F1, { ModifierKey.CONTROL }, function() print("[MyLuaMod] Key pressed\n") ExecuteInGameThread(function() ReadPlayerLocation() end)
end)

When you load the game until you can move the character, press the hotkey, move the player, press it again, the mod will generate a following

output or something very similar:

... [2024-01-09 19:37:27] Starting Lua mod 'MyLuaMod' [2024-01-09 19:37:27] [Lua] [MyLuaMod] Mod loaded ... [2024-01-09 19:37:32] [Lua] [MyLuaMod] Key pressed [2024-01-09 19:37:32] [Lua] [MyLuaMod] Player location: {X=-63.133, Y=4.372, Z=90.000} [2024-01-09 19:37:39] [Lua] [MyLuaMod] Key pressed [2024-01-09 19:37:39] [Lua] [MyLuaMod] Player location: {X=788.232, Y=-639.627, Z=90.000} [2024-01-09 19:37:39] [Lua] [MyLuaMod] Player moved: {delta_X=851.364, delta_Y=-643.999, delta_Z=0.000} ...

Using Custom Lua Bindings

To make development of Lua mods easier, we’ve added the ability to dump custom Lua bindings from your game. We also have a shared types file that contains default UE types and the API functions/classes/objects that are available to you.

Dumping Custom Lua Bindings
Simply open the Dumpers tab in the GUI console window and hit the “Dump Lua Bindings” button. The generator will place the files into the Mods/shared/types folder.
Warning: Do not include any of the generated files in your Lua scripts. If they are included, any globals set by UE4SS will be overridden and things will break.

To Use Bindings
I recommend using Visual Studio Code to do your Lua development. You can install the extension just called “Lua” by sumneko.
Open the Mods folder as a workspace. You can also save this workspace so you don’t have to do this every time you open VS Code.
When developing your Lua mods, the language server should automatically parse all the types files and give you intellisense.
Warning: For many games the number of types is so large that the language server will fail to parse everything. In this case, you can add a file called .luarc.json into the root of your workspace and add the following:

{ "$schema":
"https://raw.githubusercontent.com/sumneko/vscodelua/master/setting/schema.json",
"workspace.maxPreload": 50000, "workspace.preloadFileSize": 5000 }

To get context sensitive information about the custom game types, you need to annotate your code. This is done by adding a comment above the function/class/object that you want to annotate.

Example
---@class ITM_MisSel_Biome_C local biome = FindFirstOf("ITM_MisSel_Biome_C")
---@type int local numMissions = biome.NumMissions
---@type FVector local soundCoords = { 420.5, 69.0, 3.1 } biome:SetSoundCoordinate(soundCoords)

C++ API

These are the C++ API functions available in UE4SS, on top of the standard libraries that C++ comes with by default and the reflected functions available in Unreal Engine.
You are expected to have a basic understanding of C++ and Unreal Engine’s C++ API before using these functions.
You may need to read code in the UEPsuedo repository (more specifically, the include/Unreal directory) to understand how to use these functions.
For version: 3.0.0.
Current status: incomplete.

Blueprint Macros

The following macros are used to manipulate blueprint functions from C++.

Note: Param names for wrappers must be identical to the names used for the function in UE, and they should then be passed to macros with a PropertyName param as shown in AActor.cpp .

This does not apply to macros with the _CUSTOM suffix.
With those macros you have to supply both the UE property name as well as the name of your C++ param.
These _CUSTOM suffixed macros are useful when the UE property name contains spaces or other characters that aren’t valid for a C++ variable.

Regular macros:
Intended for normal use by modders.
UE_BEGIN_SCRIPT_FUNCTION_BODY:
Finds non-native (meaning BP) UFunction by its full name without the type prefixed, throws if not found.
UE_BEGIN_NATIVE_FUNCTION_BODY:
Same as above except for native, meaning non-BP UFunctions. See: AActor::K2_DestroyActor
UE_SET_STATIC_SELF:
Used for static functions, and should be the CDO to the class that the UFunction belongs to. See: UKismetNodeHelperLibrary::GetEnumeratorUserFriendlyName.

UE_COPY_PROPERTY:

Copies the property of the supplied name into the already allocated params struct.

Param 1: The name, without quotes, of a property that exists for this UFunction. Param 2: The type that you want the underlying value to be copied as. For example, without quotes, “float” for FFloatProperty .

UE_COPY_PROPERTY_CUSTOM:
Copies the property of the supplied name into the already allocated params struct.
Param 1: The name, without quotes, of a property that exists for this UFunction. Param 2: A C++ compatible variable name for the property. Param 3: The type that you want the underlying value to be copied as. For example, without quotes, “float” for FFloatProperty .

UE_COPY_STRUCT_PROPERTY_BEGIN:
Begins the process of copying an entire struct.
Param 1: The name, without quotes, of an FStructProperty that exists for this UFunction.

UE_COPY_STRUCT_PROPERTY_CUSTOM_BEGIN:
Begins the process of copying an entire struct.
Param 1: The name, without quotes, of an FStructProperty that exists for this UFunction. Param 2: A C++ compatible variable name for the property.

UE_COPY_STRUCT_INNER_PROPERTY:
Copies a property from within an FStructProperty into the already allocated params struct.

Param 1: The name, without quotes, of the FStructProperty supplied to UE_COPY_STRUCT_PROPERTY_BEGIN . Param 2: The name, without quotes, of a property that exists in the supplied FStructProperty . Param 3: The type that you want the underlying value to be copied as. For example, without quotes, “float” for FFloatProperty . Param 4: The name of the C++ variable that you’re copying.

See: AActor::K2_SetActorRotation

UE_COPY_STRUCT_INNER_PROPERTY_CUSTOM:
Param 1: The name, without quotes, of the FStructProperty supplied to UE_COPY_STRUCT_PROPERTY_BEGIN . Param 2: The name, without quotes, of a property that exists in the supplied FStructProperty . Param 3: A C++ compatible variable name for the property. Param 4: The type that you want the underlying value to be copied as. For example, without quotes, “float” for FFloatProperty . Param 5: The name of the C++ variable that you’re copying.

UE_COPY_OUT_PROPERTY:
Copies the out property of the supplied name from the params struct into the supplied C++ variable.
This means the wrapper param (which is named the same as the property supplied) must be a reference, meaning suffixed with a “&”.
Param 1: The name, without quotes, of a property that exists for this UFunction. Param 2: The type that you want the underlying value to be copied as. For example, without quotes, “float” for FFloatProperty .
See: UGameplayStatics::FindNearestActor

UE_COPY_OUT_PROPERTY_CUSTOM:
Copies the out property of the supplied name from the params struct into the supplied C++ variable.
Param 1: The name, without quotes, of a property that exists for this UFunction.

Param 2: A C++ compatible variable name for the property. Param 3: The type that you want the underlying value to be copied as. For example, without quotes, “float” for FFloatProperty .

This means the wrapper param (which is named the same as the property supplied) must be a reference, meaning suffixed with a “&”.

UE_COPY_VECTOR:
Helper for copying an FVector. Must use UE_COPY_STRUCT_PROPERTY_BEGIN first.
Param 1: The C++ name, without quotes, of the FVector to copy from. Param 2: The name, without quotes, of the FVector, same as supplied to UE_COPY_STRUCT_PROPERTY_BEGIN .

UE_COPY_STL_VECTOR_AS_TARRAY:
Helper for copying a TArray.
Param 1: The name, without quotes, of an FArrayProperty that exists for this UFunction. Param 2: The C++ type, without quotes, that the TArray holds. For example, without quotes, “float”, for FFloatProperty . Param 3: The C++ that the contents of the TArray will be copied into.

UE_CALL_FUNCTION:
Performs a non-static function call. All non-out params must be copied ahead of this.

UE_CALL_STATIC_FUNCTION:
Performs a static function call, using the CDO provided by UE_SET_STATIC_SELF as the static instance. All non-out params must be copied ahead of this.

UE_RETURN_PROPERTY:
Copies the underlying value that the UFunction returned and returns it.

Param 1: The type that you want the underlying value to be copied as. For example, without quotes, “float” for FFloatProperty .

UE_RETURN_PROPERTY_CUSTOM:
Param 1: The type that you want the underlying value to be copied as. For example, without quotes, “float” for FFloatProperty . Param 2: The name, without quotes, for the property of this function where the return value will be copied from.

UE_RETURN_VECTOR:
Helper for returning an FVector .

UE_RETURN_STRING:
Helper for returning an FStrProperty . Converts to StringType .

UE_RETURN_STRING_CUSTOM:
Helper for returning an FStrProperty . Converts to StringType .
Param 1: The name, without quotes, for the FStrProperty of this function where the return value will be copied from.

WITH_OUTER:
Used for templated C++ types passed to macros, like TArray or TMap.
For example, pass, without quotes, WITH_OUTER(TMap, FName, int) instead of TMap<FName, int> to all macros.

Internal macros
These are only used by other macros, or by users of our C++ API if they properly understand the internals of the macros, and this requires preexisting knowledge around how UFunctions work, and you’ll likely have to BPMacros.hpp to understand how to use them properly.

UE_BEGIN_FUNCTION_BODY_INTERNAL:

Throws if the UFunction doesn’t exist, and allocates enough space (on the stack when possible, otherwise the heap) for the params and return value(s).

UE_COPY_PROPERTY_INTERNAL:
Finds the property, and throws if not found.

UE_COPY_PROPERTY_CUSTOM_INTERNAL:
Finds the property with the supplied name, and throws if not found.

UE_RETURN_PROPERTY_INTERNAL:
Finds the property to be used for the return value, throws if not found.

## C++ Examples

Template repository for making UE4SS C++ mods: UE4SSCPPTemplate
Example repo 1: kismet-debugger - trumank

Creating a C++ mod

This guide will help you create a C++ mod using UE4SS. It’s split up into four parts. Part one goes over the prerequisites. Part two goes over creating the most basic C++ mod possible. Part three will show you how to interact with UE4SS and UE itself (via UE4SS). Part four will cover installation of the mod.

The guide requires having a working C++ development environment with cmake and git , preferably similar to the one required to build UE4SS itself from sources.

Part 1
1. Make an Epic account and link it to your GitHub account 2. Check your email and accept the invitation to the @EpicGames
GitHub organization for Unreal source access. 3. Make a directory somewhere on your computer, the name doesn’t
matter but I named mine MyMods . 4. Clone the RE-UE4SS repo so that you end up with MyMods/RE-UE4SS . 5. Open CMD and cd into RE-UE4SS and execute: git submodule
update --init --recursive
6. Go back to the MyMods directory and create a new directory, this directory will contain your mod source files. I named mine MyAwesomeMod .
7. Create a file called CMakeLists.txt inside MyMods and put this inside it:
cmake_minimum_required(VERSION 3.18)
project(MyMods)
add_subdirectory(RE-UE4SS) add_subdirectory(MyAwesomeMod)

## Part #2

1. Create a file called CMakeLists.txt inside MyMods/MyAwesomeMod and put this inside it:

cmake_minimum_required(VERSION 3.18)
set(TARGET MyAwesomeMod) project(${TARGET})
add_library(${TARGET} SHARED "dllmain.cpp") target_include_directories(${TARGET} PRIVATE .) target_link_libraries(${TARGET} PUBLIC UE4SS)

2. Make a file called dllmain.cpp in MyMods/MyAwesomeMod and put this inside it:

#include <stdio.h> #include <Mod/CppUserModBase.hpp>

class MyAwesomeMod : public RC::CppUserModBase { public:
MyAwesomeMod() : CppUserModBase() {
ModName = STR("MyAwesomeMod"); ModVersion = STR("1.0"); ModDescription = STR("This is my awesome mod"); ModAuthors = STR("UE4SS Team"); // Do not change this unless you want to target a UE4SS version // other than the one you're currently building with somehow. //ModIntendedSDKVersion = STR("2.6");

printf("MyAwesomeMod says hello\n"); }

~MyAwesomeMod() override { }

auto on_update() -> void override { } };

#define MY_AWESOME_MOD_API __declspec(dllexport) extern "C" {
MY_AWESOME_MOD_API RC::CppUserModBase* start_mod() {
return new MyAwesomeMod(); }

MY_AWESOME_MOD_API void uninstall_mod(RC::CppUserModBase* mod)
{ delete mod;
} }

3. In the command prompt, in the MyMods directory, execute: cmake -
S . -B Output
4. Open MyMods/Output/MyMods.sln 5. Make sure that you’re set to the Release configuration unless you
want to debug. 6. Find your project (in my case: MyAwesomeMod) in the solution
explorer and right click it and hit Build .

## Part #3

In this part, we’re going to learn how to log to file, and both consoles, as well as find a UObject by name, and log that name.
1. Add #include <DynamicOutput/DynamicOutput.hpp> under #include <Mod/CppUserModBase.hpp> . You can now also remove #include <stdio.h> because we’ll be removing the use of printf which was the only thing that required it.
2. To save some time and annoyance and make the code look a bit better, add this line below all the includes:

using namespace RC;

3. Replace the call to printf in the body of the MyAwesomeMod constructor with:

Output::send<LogLevel::Verbose>(STR("MyAwesomeMod says hello\n"));

It’s longer than a call to printf , but in return the message gets propagated to the log file and both the regular console and the GUI console. We also get some support for colors via the LogLevel enum.
4. Add this below the DynamicOutput include:

#include <Unreal/UObjectGlobals.hpp> #include <Unreal/UObject.hpp>

5. Let’s again utilize the using namespace shortcut by adding this below the first one: using namespace RC::Unreal;
6. Add this function in your mod class:

auto on_unreal_init() -> void override {
// You are allowed to use the 'Unreal' namespace in this function and anywhere else after this function has fired.
auto Object = UObjectGlobals::StaticFindObject<UObject*> (nullptr, nullptr, STR("/Script/CoreUObject.Object"));
Output::send<LogLevel::Verbose>(STR("Object Name: {}\n"), Object->GetFullName()); }

Note that Output::send doesn’t require a LogLevel and that we’re using {} in the format string instead of %s .

The Output::send function uses std::format in the back-end so you should do some research around std::format or libfmt if you want to know more about it.

7. Right click your project and hit Build .

Part #4
Click to go to guide for installing a C++ Mod

Installing a C++ Mod

1. This part assumes you have UE4SS installed and working for your game already. If not, refer to the installation guide.
2. After building, you will have the following file:
MyAwesomeMod.dll in MyMods\Output\MyAwesomeMod\Release
3. Navigate over to your game’s executable folder and open the Mods folder. Here we’ll do a couple things:
Create a folder structure in Mods that looks like MyAwesomeMod\dlls . Move MyAwesomeMod.dll inside the dlls folder and rename it to main.dll .
The result should look like:
Mods\ MyAwesomeMod\ dlls\ main.dll
4. To enable loading of your mod in-game you will have to edit the mods.txt located in the Mods folder. By default it looks something like this:
CheatManagerEnablerMod : 1 ActorDumperMod : 0 ConsoleCommandsMod : 1 ConsoleEnablerMod : 1 SplitScreenMod : 0 LineTraceMod : 1 BPModLoaderMod : 1 jsbLuaProfilerMod : 0

; Built-in keybinds, do not move up! Keybinds : 1
Here you will want to add the line:
MyAwesomeMod : 1
above the keybinds to enable MyAwesomeMod .

Alternatively, place an empty text file named enabled.txt inside of the MyAwesomeMod folder. This method is not recommended because it does not allow load ordering and bypasses mods.txt, but may allow for easier installation by end users.

5. Launch your game and if everything was done correctly, you should see the text “MyAwesomeMod says hello” highlighted in blue somewhere at the top of UE4SS console.

Creating GUI tabs with a C++ mod

UE4SS already includes the ImGui library to render its console GUI, built from the UE4SS-RE/imgui repo. Refer to ImGui documentation in that repo on how to use ImGui-specific classes and methods for rendering actual buttons and textboxes and other window objects.
This guide will show how you create custom tabs for the GUI with a C++ mod, and the guide will take the form of comments in the code example below:

#include <Mod/CppUserModBase.hpp> #include <UE4SSProgram.hpp>

class MyAwesomeMod : public RC::CppUserModBase { private:
int m_private_number{33}; std::shared_ptr<GUI::GUITab> m_less_safe_tab{};

public: MyAwesomeMod() : CppUserModBase() { ModName = STR("MyAwesomeMod"); ModVersion = STR("1.0"); ModDescription = STR("This is my awesome mod"); ModAuthors = STR("UE4SS Team");

// It's critical that you enable ImGui before you create your tab.
// If you don't do this, a crash will occur as soon as ImGui tries to render anything in your tab.
UE4SS_ENABLE_IMGUI()

// The 'register_tab' function will tell UE4SS to render a tab.
// Tabs registered this way will be automatically cleaned up when this C++ mod is destructed.
// The first param is the display name of your tab. // The second param is a callback that UE4SS will use to render the contents of the tab. // The param to the callback is a pointer to your mod. register_tab(STR("My Test Tab"), [](CppUserModBase* instance) {
// In this callback, you can start rendering the contents of your tab with ImGui.
ImGui::Text("This is the contents of the tab");

// You can access members of your mod class with the 'instance' param.
auto mod = dynamic_cast<MyAwesomeMod*>(instance); if (!mod) {
// Something went wrong that caused the 'instance' to not be correctly set.
// Let's abort the rest of the function so that you don't access an invalid pointer.
return; }

// You can access both public and private members. mod->render_some_stuff(mod->m_private_number); });

// The 'UE4SSProgram::add_gui_tab' function is another way to tell UE4SS to render a tab.
// This way of registering a tab will make you responsible for cleaning up the tab when your mod destructs.

// Failure to clean up the tab on mod destruction will result in a crash.
// It's recommended that you use 'register_tab' instead of this function.
m_less_safe_tab = std::make_shared<GUI::GUITab>(STR("My Less Safe Tab"), [](CppUserModBase* instance) {
// This callback is identical to the one used with 'register_tab' except 'instance' is always nullptr.
ImGui::Text("This is the contents of the less safe tab");
});

UE4SSProgram::get_program().add_gui_tab(m_less_safe_tab); }

~MyAwesomeMod() override {
// Because you created a tab with 'UE4SSProgram::add_gui_tab', you must manually remove it.
// Failure to remove the tab will result in a crash.

UE4SSProgram::get_program().remove_gui_tab(m_less_safe_tab); }

auto render_some_stuff(int Number) -> void {
auto calculated_value = Number + 1; ImGui::Text(std::format("calculated_value: {}", calculated_value).c_str()); } };

#define MY_AWESOME_MOD_API __declspec(dllexport) extern "C" {
MY_AWESOME_MOD_API RC::CppUserModBase* start_mod() {
return new MyAwesomeMod(); }

MY_AWESOME_MOD_API void uninstall_mod(RC::CppUserModBase* mod)
{ delete mod;
} }

Fixing missing AOBs

If UE4SS won’t properly start because of missing AOBs, you can provide your own AOB and callback using Lua.
For this guide you’ll need to know what a root directory and working directory is. A root directory is always the directory that contains ue4ss.dll . A working directory is either the directory that contains ue4ss.dll OR a game specific directory, for example <root directory>/SatisfactoryEarlyAccess .

How to find AOBs
Since the process is quite complicated, here will just cover the general steps you need to take.
1. Make a blank shipped game in your game’s UE version, with PDBs 2. Read game’s memory using x64dbg 3. Look for the signature you need - those can be found below 4. Grab a copy of the bytes from that function, sometimes the header
is enough. If it is not, it may be better to grab a call to the function and if it’s not a virtual function, you can grab the RIP address there 5. Open your game’s memory in x64dbg and search it for the same block of bytes 6. If you find it, you can use the swiss army knife tool to extract the AOB for it which you can use in a simple script such as example here

How to setup your own AOB and callback
1. Create the directory UE4SS_Signatures if it doesn’t already exist in your working directory .
2. Identify which AOBs are broken and needs fixing. 3. Make the following files inside UE4SS_Signatures , depending on
which AOBs are broken: GUObjectArray.lua FName_ToString.lua FName_Constructor.lua FText_Constructor.lua StaticConstructObject.lua GMalloc.lua

4. Inside the .lua file you need a global Register function with no params Keep in mind that the names of functions in Lua files in the UE4SS_Signatures directory are case-senstive.
5. The Register function must return the AOB that you want UE4SS to scan for. The format is a list of nibbles, and every two forms a byte. I like putting a space between each byte just for clarity but this is not a requirement. An example of an AOB: 8B 51 04 85 . Another example of an AOB: 8B510485 . The AOB scanner supports wildcards for either nibble or the entire byte.
6. Next you need to create a global OnMatchFound function. This function has one param, MatchAddress , and this is the address of the match. It’s in this function that you’ll place all your logic for calculating the final address. The most simple way to do this is to make sure that your AOB leads directly to the start of the final address. That way you can simply return MatchAddress . In the event that you’re doing something more advanced (e.g. indirect aob scan), UE4SS makes available two global functions, DerefToInt32 which takes an address and returns, as a 32-bit integer, whatever data is located there OR nil if the address could not be dereferenced, and print for debugging purposes.

What ‘OnMatchFound’ must return for each AOB
GUObjectArray Must return the exact address of the global variable named ‘GUObjectArray’.
FName_ToString Must return the exact address of the start of the function ‘FName::ToString’. Function signature: public: void cdecl
FName::ToString(class FString & ptr64)const __ptr64
FName_Constructor Must return the exact address of the start of the function ‘FName::FName’.

This callback is likely to be called many times and we do a check behind the scenes to confirm if we found the right constructor. It doesn’t matter if your AOB finds both ‘char*’ versions and ‘wchar_t*’ versions. Function signature: public: cdecl FName::FName(wchar_t
const * ptr64,enum EFindName) __ptr64
FText_Constructor Must return the exact address of the start of the function ‘FText::FText’. Function signature: public: cdecl FText::FText(class
FString & ptr64)const __ptr64
StaticConstructObject Must return the exact address of the start of the global function ‘StaticConstructObject_Internal’. In UE4SS, we scan for a call in the middle of ‘UUserWidget::InitializeInputComponent’ and then resolve the call location. Function signature: class UObject * __ptr64 __cdecl
StaticConstructObject_Internal(struct
FStaticConstructObjectParameters const & __ptr64)
GMalloc Must return the exact address of the global variable named ‘GMalloc’. In UE4SS, we scan for ‘FMemory::Free’ and then resolve the MOV instruction closest to the first CALL instruction.

Example script (Simple, direct scan)
function Register() return "48 8B C4 57 48 83 EC 70 80 3D ?? ?? ?? ?? ?? 48 89"
end
function OnMatchFound(MatchAddress) return MatchAddress
end

Example script (Advanced, indirect scan)

function Register() return "41 B8 01 00 00 00 48 8D 15 ?? ?? ?? ?? 48 8D 0D ??
?? ?? ?? E9" end
function OnMatchFound(MatchAddress) local InstrSize = 0x05
local JmpInstr = MatchAddress + 0x14 local Offset = DerefToInt32(JmpInstr + 0x1) local Destination = JmpInstr + Offset + InstrSize
return Destination end

Generating UHT compatible headers

Supported versions
While the UHT header generator is only officially supported in 4.25+ , it has worked for older game versions (tested on 4.18.3 ; 4.17 (has some default property issues that should be fixed soon)). It also works for 5.0+ .
How to use
The key bind to generate headers is by default CTRL + Numpad 9 , and it can be changed in Mods/Keybinds/Scripts/main.lua .
To utilize the generated headers to their full potential, see UE4GameProjectGenerator by Archengius (link to Buck’s fork because of a couple fixes that Arch is too lazy to merge).
The project generator will only compile for UE versions 4.22 and higher. Engine customizations by developers may lead to unexpected results. If generating a project for an engine version older than 4.22 , generate it by compiling the project generator for 4.22 or higher first.
Before compiling the projectgencommandlet, open GameProjectGenerator.uproject and your game’s pluginmanifest or .uproject and add any default engine plugins used by the game or plugins that the game uses and you found open source or purchased (it is not recommended to include purchased plugins in a public uproject) to the commandlet’s uproject file.
After compiling the commandlet and running it on your game files, simply change the engine version in the generated .uproject to the correct engine version for your game.

This commandlet (by Spuds) will enter the CLI commands for the project gen for you, and make a batch file to regenerate with the same settings (e.g., to regenerate after a major game update).

Possible inaccurate generation issues:
UE4SS has two different types of generators, a UHT compatible generator and what’s called a CXX generator.
The UHT compatible generator is what’s used when creating a .uproject file with the UE4GameProjectGenerator, and the CXX generator is a very shoddily made generator that doesn’t generate UHT macros or proper #include statements but it does generate headers for core UE classes which the UHT generator doesn’t.
Note the UE4SS CXX dumps do not currently have accurate padding. An SDK dump generated from another source may be a better

source for determining the below corrections if it generates with correct padding, particularly for the bitfield checks.

Certain default properties may not generate correctly in older engine versions. For example, SoftObjectProperty was called AssetObjectProperty and SoftClassProperty was AssetClassProperty in < 4.17 . It is recommended to also generate an SDK/CXX dump to check for those properties and correct them in your project.
Bitfields will always generate as uint8 . However, they may actually be declared as uint32 in the original source. You can try to determine the actual size based on the CXX/SDK dump to correct these. In a CXX dump the bitfields will show the same offset. If there are multiple bitfields at the same offset and the next property is 4 bytes after that offset, then the bitfield should be changed to uint32.

Instructions for possible errors you may encounter
These are some general instructions of how to generate a project and it also covers a few errors that you are likely to encounter.
The following errors & solutions is what was found when generating projects for various games.
Note that you can check here for solutions even if your game isn’t listed below. Error lists compiled by Buckminsterfullerene, CheatingMuppet, Narknon & Blubb.

Inherited Virtuals
UE4SS is unable to generate inherited virtuals if they are unreflected. This is often the source of LNK2001: unresolved external symbol errors, particularly when a class inherits from an interface. The build log is often not helpful for determining which file needs these virtuals.
To determine the file that they need to be added to, search for the virtual function listed in the error or for the class of the function in the engine, e.g., Module.AkAudio.cpp.obj : error LNK2001: unresolved external
symbol "public: virtual class FString const __cdecl
UInterpTrack::GetEdHelperClassName(void)const you could search for

GetEdHelperClassName or UInterpTrack . Find the parent function and then find any classes within your project that inherit from same. Ideally find a sample of another class that inherits those virtuals within the engine on which to base your fixes, and copy the implementations from same into your affected project files, being sure to change the class name to match the class in your project.

You typically will also want to delete the logic in the implementations to simply return the correct type of data or “null” without actually running any logic.

Game Target Generation
The project gen commandlet does not generate a game target file. Copy and duplicate your GameNameEditor.target.cs file in the same location. Remove Editor from the name. Open the file and delete “Editor” in the red crossed locations, and replace “Editor” with “Game” in the highlighted location.

## Deep Rock Galactic

========================== First do: ========================== Generate project using commandlet Then open it in Rider/VS.
========================== Then do, in no particular order: ========================== Find out what version of mod.io game currently uses. At time of writing it is https://github.com/modio/modioue4/releases/tag/v2.16.1792. Delete the existing 'Modio' folder first. Paste the 'Modio', 'ModioTests' and 'ThirdParty' folders from this into Plugins/Modio/Source, replacing the existing 'Modio' folder. Do not replace the .uplugin file. Delete the ModioEx section form the .uplugin file instead.
In: - CharacterSightSensor.h, FCharacterSightSensorDelegates DECLARE_DYNAMIC_MULTICAST_DELEGATE(FCharacterSightSensorDelegat e); - FSDProjectileMovementComponent.h top delegates DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnProjectilePenetrateDelega te); DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnProjectileOutOfPropulsion ); Add the macro DECLARE_DYNAMIC_MULTICAST_DELEGATE(<\DelegateName>); above the UCLASS
In: - SubHealthComponent.h, line 56 - HealthComponentBase.h, line 117 - HealthComponent.h, line 98 - EnemyHealthComponent.h, line 39 - FriendlyHealthComponent.h, line 33 Comment out UFUNCTION
Errors that look like this: "ActorFunctionLibrary.gen.cpp(153): [C2664] 'void UActorFunctionLibrary::DissolveMaterials(UObject *,const UMeshComponent *&,float)': cannot convert argument 2 from 'UMeshComponent *' to 'const UMeshComponent *&'": Remove the const before the arguments that have the error (remember to also remove them in the definition stub too) OR use this regex string (const) ((\w+)\*\&) and replace with $2
In "ShowroomStage.cpp" inside of the implementation of the constructor, comment out "this->SceneCapture = CreateDefaultSubobject<\USceneCaptureComponent2D> (TEXT("SceneCapture"));"
Set supported platforms to windows

cyubeVR

Add the following 4 lines in the "Plugins" section in the generated "cyubeVR.uproject": {
"Name": "ChaosEditor", "Enabled": false }
Copy and paste the cyubeVREditor.Target.cs file (inside Source folder) and name it cyubeVRGame.Target.cs. Then replace any mentions of "editor" and replace with "game" inside of this new file
Right click generated project and open with IDE (e.g. Rider)
Comment out UFUNCTION() in ReceiveLightActor.h - UseActorCustomLocation - GetActorCustomLocation
Set the "_MAX UMETA(Hidden)," to "_MAX = 0xFF UMETA(Hidden)," in:
- EUGCMatchingUGCTypeBP.h - EItemPreviewTypeBP.h
Remove the constructor from IpNetDriverUWorks.h and cpp files.
Remove TEnumAsByte<> (but not the type inside of it) in: - OnInput inside VRGripInterface.h - OnEndPlay inside VRGripScriptBase.h and its
_Implementation version in the .cpp file - SetMobilityAllEvent inside DeerCPP.h and its
_Implementation version in the .cpp file
Then right click the .uproject and hit "regenerate solution files".
If you get the "failed to create version memory for PCH" errors when trying to build or pack, do it again.

## Game 3

Error 1 In an Enum class: System.ArgumentException - String cannot contain a minus sign if the base is not 10.
Fix: Remove the BlueprintType meta tag and the uint8 override on the enum ': uint8'.

Error 2 Unable to find 'class', 'delegate', 'enum', or 'struct' with name 'XYZ', where XYZ is an FStruct used within a class with no separate UStruct declaration.
Fix: DECLARE_DYNAMIC_MULTICAST_DELEGATE(XYZ); , close to the Top of header Files.

Error 3 "is not supported by blueprint."
Fix: -> Remove BlueprintReadWrite -> or Remove BlueprintCallable

Error 4 cannot instantiate abstract class
fix:
cpp looks like:
UAbilitySystemComponent* AActorWithGAS::GetAbilitySystemComponent() const {
return nullptr; }
Go to Header File and add:
UAbilitySystemComponent* GetAbilitySystemComponent() const override;

Error 5 modifiers not allowed on static member functions
Fix: Remove the modifier, like "const"
Example: static TSoftObjectPtr<Test> SomeFunction(some args) const; <remove const

In both h and cpp File.

Error 6 'AAkAMbientSound' no appropriate default consturctor available.
Fix: ------Header File ------AkAmbientSound();
->
AkAmbientSound(const class FObjectInitializer& ObjectInitializer);
------CPP File ------AkAmbientSound::AkAmbientSound() {
this->AkEvent = NULL; }
->
AkAmbientSound::AkAmbientSound(const class FObjectInitializer& ObjectInitializer) : Super(ObjectInitializer) {
this->AkEvent = NULL; }

## Astro Colony

========================== First do: ========================== Generate project using commandlet Then open it in Rider/VS.
========================== Then do, in no particular order: ========================== Copy the EditorTarget file, rename it to AstroColonyGame.Target, and inside of it change target type to Game
In: - VoxelPhysicsPartSpawner_VoxelWorlds.h, FConfigureVoxelWorld; - TGNamedSlot.h, FOnNamedSlotAdded/Removed - EHLogicObject.h, FOnSelectedResourcesChanged - EHSignalObject.h, FOnResourcesSignalOutChanged/FOnSelectedDeviceChanged - EHInteractableServiceObject, FOnAIInsideChanged - EHModsBrowsedOptionViewModel, FOnInstalProgressChanged/FOnInstalCompleted - EHSaveLoadListViewModel, FOnScenarioDetailsUpdated - EHTrainingObject, FOnTrainedChanged - EHSchoolObject, FOnAwaitingSpecialistTrainingsChange - EHSignalReceiver, FOnSignalSendChanged - EHModsListViewModel, FOnModsOptionSelected - EHSignalNetwork, FOnSignalChanged - AbilityAsync_WaitGameplayTagAdded, FAsyncWaitGameplayTagDelegate (put it inside of AbilityAsync_WaitGameplayTag) Add the macro DECLARE_DYNAMIC_MULTICAST_DELEGATE(<\DelegateName>); above the UCLASS
In: - AbilityAsync_WaitGameplayTagRemoved.h - AbilityAsync_WaitGameplayTagAdded.h Remove the UAbilityAsync_WaitGameplayTag:: from the front of each member
In EHSummaryViewModel.h add #include "EHSaveLoadListViewModel.h"
In: - MaterialExpressionBlendMaterialAttributesBarycentric.h (every property) - MaterialExpressionUnpack.h (FExpressionInput Input) - GameplayCueInterface.h (ForwardGameplayCueToParent) remove BlueprintReadWrite/BlueprintCallable (where appropriate) flag from the 'UPROPERTY' macro.
In MaterialPackInput.h, add #include "MaterialExpressionIO.h" and remove BlueprintReadWrite flag from the 'UPROPERTY' macro for FExpressionInput Input;
In EAbilityTaskWaitState.h, add None = 0 to the enum

In: - AbilityTask.h/.cpp - UMovieSceneGameplayCueTriggerSection - UMovieSceneGameplayCueSection comment out the constructor/definition

In AbilitySystemComponent.h/.cpp, comment out: - The constructor - ServerSetReplicatedEventWithPayload - ServerSetReplicatedEvent - ClientSetReplicatedEvent

In EHBaseButtonWidget.h, add: #include "Components/HorizontalBox.h" #include "Components/BackgroundBlur.h" #include "Components/SizeBox.h" then remove the forward declarations for UHorizontalBox, UBackgroundBlur, USizeBox. Then comment out
UFUNCTION(BlueprintImplementableEvent) void OnInputControllerChanged(TEnumAsByte<ETGInputControllerType> InputControllerType);

In: - EHPlanetoidDestructibleItem.h - EHPlanetoidVisualItem.h (also remove array from SpawnDensity) - EHGridComponent.h, BillboardTextures - EHHUDGame.h, PopMenuClasses/HUDMenuClasses (also change GetPopMenuClass return type) - EHScenarioParams.h, TerrainTypeSpawnChances/ShapeTypeSpawnChances - EHDataProvider.h, every array replace the array decleration with TArray<> and add BlueprintReadWrite+other normal flags to the 'UPROPERTY' macro. Then update the .cpp constructor.

In VoxelProceduralMeshComponent.h/.cpp, add the UPrimitiveComponent interface, i.e. like this: VoxelProceduralMeshComponent.h: #pragma once #include "CoreMinimal.h" #include "Components/ModelComponent.h" #include "VoxelIntBox.h" #include "VoxelProceduralMeshComponent.generated.h"

class UBodySetup; class UStaticMeshComponent; class AVoxelWorld; class UModelComponent;

UCLASS(Blueprintable, ClassGroup=Custom, meta= (BlueprintSpawnableComponent)) class VOXEL_API UVoxelProceduralMeshComponent : public UModelComponent {
GENERATED_BODY() public: private:

UPROPERTY(BlueprintReadWrite, EditAnywhere, Transient, meta=(AllowPrivateAccess=true))
UBodySetup* BodySetup;

UPROPERTY(BlueprintReadWrite, EditAnywhere, Transient, meta=(AllowPrivateAccess=true))
UBodySetup* BodySetupBeingCooked;

UPROPERTY(BlueprintReadWrite, EditAnywhere, Export, Transient, meta=(AllowPrivateAccess=true))
UStaticMeshComponent* StaticMeshComponent;

public: UVoxelProceduralMeshComponent(const FObjectInitializer&
ObjectInitializer); UFUNCTION(BlueprintCallable) static void SetVoxelCollisionsFrozen(const AVoxelWorld*
VoxelWorld, bool bFrozen);

UFUNCTION(BlueprintImplementableEvent) void InitChunk(uint8 ChunkLOD, FVoxelIntBox ChunkBounds);

UFUNCTION(BlueprintCallable, BlueprintPure) static bool AreVoxelCollisionsFrozen(const AVoxelWorld* VoxelWorld);

//~ Begin UPrimitiveComponent Interface. virtual void
CreateRenderState_Concurrent(FRegisterComponentContext* Context) override;
virtual void DestroyRenderState_Concurrent() override; virtual bool GetLightMapResolution( int32& Width, int32& Height ) const override; virtual int32 GetStaticLightMapResolution() const override; virtual void GetLightAndShadowMapMemoryUsage( int32& LightMapMemoryUsage, int32& ShadowMapMemoryUsage ) const override; virtual FBoxSphereBounds CalcBounds(const FTransform& LocalToWorld) const override; virtual FPrimitiveSceneProxy* CreateSceneProxy() override; virtual bool ShouldRecreateProxyOnUpdateTransform() const override; #if WITH_EDITOR virtual void GetStaticLightingInfo(FStaticLightingPrimitiveInfo& OutPrimitiveInfo,const TArray<ULightComponent*>& InRelevantLights,const FLightingBuildOptions& Options) override; virtual void AddMapBuildDataGUIDs(TSet<FGuid>& InGUIDs) const override; #endif virtual ELightMapInteractionType GetStaticLightingType() const override { return LMIT_Texture; } virtual void GetStreamingRenderAssetInfo(FStreamingTextureLevelContext& LevelContext, TArray<FStreamingRenderAssetPrimitiveInfo>& OutStreamingRenderAssets) const override; virtual void GetUsedMaterials(TArray<UMaterialInterface*>&

OutMaterials, bool bGetDebugMaterials = false) const override; virtual class UBodySetup* GetBodySetup() override { return
ModelBodySetup; }; virtual int32 GetNumMaterials() const override; virtual UMaterialInterface* GetMaterial(int32
MaterialIndex) const override; virtual UMaterialInterface*
GetMaterialFromCollisionFaceIndex(int32 FaceIndex, int32& SectionIndex) const override;
virtual bool IsPrecomputedLightingValid() const override; //~ End UPrimitiveComponent Interface.

//~ Begin UActorComponent Interface. virtual void InvalidateLightingCacheDetailed(bool bInvalidateBuildEnqueuedLighting, bool bTranslationOnly) override; virtual void PropagateLightingScenarioChange() override; //~ End UActorComponent Interface.

//~ Begin UObject Interface. virtual void Serialize(FArchive& Ar) override; virtual void PostLoad() override; virtual bool IsNameStableForNetworking() const override; #if WITH_EDITOR virtual void PostEditUndo() override; #endif // WITH_EDITOR static void AddReferencedObjects(UObject* InThis, FReferenceCollector& Collector); //~ End UObject Interface.

//~ Begin Interface_CollisionDataProvider Interface virtual bool GetPhysicsTriMeshData(struct FTriMeshCollisionData* CollisionData, bool InUseAllTriData) override; virtual bool ContainsPhysicsTriMeshData(bool InUseAllTriData) const override; virtual bool WantsNegXTriMesh() override { return false; } //~ End Interface_CollisionDataProvider Interface

//#if WITH_EDITOR

/**

* Generate the Elements array.

*

* @param bBuildRenderData

If true, build render

data after generating the elements.

*

* @return bool

true if

successful, false if not.

*/

virtual bool GenerateElements(bool bBuildRenderData);

//#endif // WITH_EDITOR

};

VoxelProceduralMeshComponent.cpp: #include "VoxelProceduralMeshComponent.h"

class AVoxelWorld;

void UVoxelProceduralMeshComponent::SetVoxelCollisionsFrozen(const AVoxelWorld* VoxelWorld, bool bFrozen) {

}

bool UVoxelProceduralMeshComponent::AreVoxelCollisionsFrozen(const AVoxelWorld* VoxelWorld) {
return false; }

UVoxelProceduralMeshComponent::UVoxelProceduralMeshComponent(co nst FObjectInitializer& ObjectInitializer) : Super(ObjectInitializer) {
this->BodySetup = NULL; this->BodySetupBeingCooked = NULL; this->StaticMeshComponent = NULL; }

void UVoxelProceduralMeshComponent::AddReferencedObjects(UObject* InThis, FReferenceCollector& Collector) {
/*UVoxelProceduralMeshComponent* This = CastChecked<UVoxelProceduralMeshComponent>(InThis);
Collector.AddReferencedObject( This->StaticMeshComponent, This );
AddReferencedObjects( This, Collector );*/ }

void UVoxelProceduralMeshComponent::Serialize(FArchive& Ar) {
/*Serialize(Ar);

Ar << StaticMeshComponent;*/ }

void UVoxelProceduralMeshComponent::PostLoad() {
/*PostLoad();

// Fix for old StaticMeshComponent components which weren't created with transactional flag.
SetFlags( RF_Transactional );

// BuildRenderData relies on the StaticMeshComponent having been post-loaded, so we ensure this by calling ConditionalPostLoad.
check(StaticMeshComponent); StaticMeshComponent->ConditionalPostLoad();*/

}

bool UVoxelProceduralMeshComponent::IsNameStableForNetworking() const {

// UVoxelProceduralMeshComponent is always persistent for the duration of a game session, and so can be considered to have a stable name
return true; }

void UVoxelProceduralMeshComponent::GetUsedMaterials(TArray<UMateria lInterface*>& OutMaterials, bool bGetDebugMaterials) const {

}

int32 UVoxelProceduralMeshComponent::GetNumMaterials() const {
return 0; }

UMaterialInterface* UVoxelProceduralMeshComponent::GetMaterial(int32 MaterialIndex) const {
UMaterialInterface* Material = nullptr;

return Material; }

UMaterialInterface* UVoxelProceduralMeshComponent::GetMaterialFromCollisionFaceInde x(int32 FaceIndex, int32& SectionIndex) const {
UMaterialInterface* Result = nullptr; SectionIndex = 0; return Result; }

bool UVoxelProceduralMeshComponent::IsPrecomputedLightingValid() const {
return false; }

void UVoxelProceduralMeshComponent::GetStreamingRenderAssetInfo(FStr eamingTextureLevelContext& LevelContext, TArray<FStreamingRenderAssetPrimitiveInfo>& OutStreamingRenderAssets) const {

}

void UVoxelProceduralMeshComponent::CreateRenderState_Concurrent(FRe gisterComponentContext* Context) {

}

void UVoxelProceduralMeshComponent::DestroyRenderState_Concurrent() {
}
FPrimitiveSceneProxy* UVoxelProceduralMeshComponent::CreateSceneProxy() {
return NULL; }
bool UVoxelProceduralMeshComponent::ShouldRecreateProxyOnUpdateTrans form() const {
return true; }
FBoxSphereBounds UVoxelProceduralMeshComponent::CalcBounds(const FTransform& LocalToWorld) const {
return FBoxSphereBounds(LocalToWorld.GetLocation(), FVector::ZeroVector, 0.f); }
void UVoxelProceduralMeshComponent::InvalidateLightingCacheDetailed( bool bInvalidateBuildEnqueuedLighting, bool bTranslationOnly) {
}
void UVoxelProceduralMeshComponent::PropagateLightingScenarioChange( ) {
}
bool UVoxelProceduralMeshComponent::GetLightMapResolution( int32& Width, int32& Height ) const {
return false; }
int32 UVoxelProceduralMeshComponent::GetStaticLightMapResolution() const {
/*int32 Width; int32 Height; GetLightMapResolution(Width, Height);
return FMath::Max<int32>(Width, Height);*/ return NULL;

}

void UVoxelProceduralMeshComponent::GetLightAndShadowMapMemoryUsage( int32& LightMapMemoryUsage, int32& ShadowMapMemoryUsage ) const {
/*return;*/ }

#if WITH_EDITOR void UVoxelProceduralMeshComponent::GetStaticLightingInfo(FStaticLig htingPrimitiveInfo& OutPrimitiveInfo,const TArray<ULightComponent*>& InRelevantLights,const FLightingBuildOptions& Options) {
/*check(0);*/ }

void UVoxelProceduralMeshComponent::AddMapBuildDataGUIDs(TSet<FGuid> & InGUIDs) const {

}

void UVoxelProceduralMeshComponent::PostEditUndo() {
/*PostEditUndo();*/ } #endif // WITH_EDITOR

bool UVoxelProceduralMeshComponent::GetPhysicsTriMeshData(struct FTriMeshCollisionData* CollisionData, bool InUseAllTriData) {
return false; }

bool UVoxelProceduralMeshComponent::ContainsPhysicsTriMeshData(bool InUseAllTriData) const {
return false; }

bool UVoxelProceduralMeshComponent::GenerateElements(bool bBuildRenderData) {
return false; }

Set supported platforms to windows

Devlogs

This section will contain a list of development logs that have been written by contributors of UE4SS. These logs are intended to be a way for contributors to share their experiences and knowledge with the community, and to provide a way for the community to understand the development process of UE4SS.

DataTables in UE4SS - bitonality (2024-02-07)

DataTables in UE4SS

Background
DataTables are a data structure in Unreal Engine that allows for hashed key-value pairs to be loaded at runtime. Common use cases include storing loot tables, experience point requirements for leveling up, base health/armor for actors, etc…
DataTables are intended to be populating as part of game compilation and aren’t technically supposed to be modified at runtime. The documentation from Unreal sometimes contradicts this statement, so it’s a bit hard to parse what’s intended versus what’s possible. My goal is to allow for full read/write/update/delete/iterate operations at runtime from a C++ context without the use of blueprints.
Why not just create a blueprint mod that replaces a DataTable?
This technically works. The problem is that your mod is the only mod that can change this DataTable. This is obviously not ideal for clients that want to use multiple mods that want to modify the same DataTable. I rate this solution around a 2/10 from a extensibility perspective.
What is the structure of a DataTable?
DataTables are build by using TMap and TSet from native Unreal. If you are familiar with Java’s HashMap or C#’s Dictionary then you’ll understand the gist of the contracts/usage. Unreal DataTable has keys of FName and the value is a struct that inherits from FTableRowBase . More on this later…

So what needs to be done?

I will outline a couple of possibilities for the modification of DataTables. I will be evaluating the feasibility/stability of each proposed solution to give some perspective.

Solution 1 (TMap implementation)
A DataTable in Unreal Engine exposes a RowMap property that can be accessed:
// DataTable.h virtual const TMap< FName, uint8 * > & GetRowMap() const virtual const TMap< FName, uint8 * > & GetRowMap()
The GetRowMap() function is reflected and is easily callable by using the UVTD files. The problem is that UE4SS has a bare-bones implementation of TMap. The current TMap implementation in UE4SS can be leveraged in the following manner:
// DataTable row format is <FName, CoolStruct> struct CoolStruct : FTableRowBase {
FString SomeString; int_32 SomeNumber; bool SomeBoolean; }
TMap<FName, unsigned char*> rowMap = dataTable->GetRowMap(); auto ptrElem = rowMap.GetElementsPtr(); for(int32_t i = 0; i < rowMap.Num(); i++) {
auto pair = &ptrElem[i]; pair->Key; pair->Value; CoolStruct* row = reinterpret_cast<CoolStruct*>(pair>Value); }
So what’s the big deal?
UE4SS’s TMap does not like when the underlying data is changed. This way of accessing data works reasonably well for DataTable reads/iterators, but after we call dt->AddRow() or dt->RemoveRow() , the underlying .GetElementsPtr() is inaccurate. If you look at the UE4SS implementation of TMap, you can see that it’s fairly fragile unless you intend to read only.

Note that the current .Num() function in UE4SS TMap does not actually perform calculations on the TMap. The Num property is just set when we construct a TMap in UE4SS, so we don’t get updates when the underlying size changes.

I suppose this solution is reasonable for reading a DataTable if that’s all you want to do.

So how can we make this work?

Theoretically we can implement TMap in UE4SS with mirrored functionality to UE native. UE4SS has done a similar approach with TArray . The potential downsides are that if TMap underlying logic/structures have changed between UE versions, then we would need multiple implementations that represent the state of UE TMaps at different versions. Either that, or, we could have #if UE5_1 etc. to keep things consolidated in a single TMap.hpp/cpp file.

Will implementing TMap in UE4SS work for modifying DataTables? I haven’t completed a thorough investigation, but my gut says… probably?

Why can’t we use FindRow/GetRow on the DataTable object?

The only useful reflected functions we get from UDataTable dump is GetRowMap() , RemoveRow() , and AddRow() . Not too shabby, but unfortunate that we can’t get a row directly or use a UE4SS TMap to get a row.

Solution 2 (Kismet DataTable Helper Library)
This approach leverages a blueprint DataTable helper class built into Unreal Engine. The reflected functions from this blueprint helper are:

static bool DoesDataTableRowExist (
UDataTable * Table, FName RowName )

static void GetDataTableRowNames (
UDataTable * Table, TArray< FName > & OutRowNames )

static bool GetDataTableRowFromName (
UDataTable * Table, FName RowName, FTableRowBase & OutRow )

If you’ve been paying attention, then a light bulb might be going off in your head. Seems like we could accomplish full DataTable support by utilizing

// DataTable reflected functions AddRow(); RemoveRow(); Empty();
// DataTableFunctionLibrary reflected functions DoesDataTableRowExist(); GetDataTableRowNames(); GetDataTableRowFromName();

But there’s always a catch…
GetDataTableRowFromName(); is an especially cursed function. The TLDR is that it’s probably usable, but will require some further experimentation.
This next section benefits from somewhat of an intimate knowledge of how Kismet/blueprints/FFrame and the blueprint scripting stack works. I’ll include some pre-reads to familiarize yourself.
Custom Thunks TLDR Blueprints from C++ Blueprint Function Templates
GetDataTableRowFromName() has the specifiers CustomThunk and CustomStructureParam .

CustomThunk: The UnrealHeaderTool code generator will not produce a thunk for this function; it is up to the user to provide one with the DECLARE_FUNCTION or DEFINE_FUNCTION macros.

CustomStructureParam: The listed parameters are all treated as wildcards. This specifier requires the UFUNCTION-level specifier, CustomThunk, which will require the user to provide a custom exec function. In this function, the parameter types can be checked and the appropriate function calls can be made based on those parameter types. The base UFUNCTION should never be called, and should assert or log an error if it is.

Under the hood, the GetDataTableRowFromName() UFunction is just a stub. The DataTableFunctionLibrary provides the actual behavior with a DEFINE_FUNCTION(execGetDataTableRowFromName) macro. Let’s take a look at what the defined function is:

// DataTableFunctionLibrary.h /** Based on UDataTableFunctionLibrary::GetDataTableRow */ DECLARE_FUNCTION(execGetDataTableRowFromName) { P_GET_OBJECT(UDataTable, Table); P_GET_PROPERTY(FNameProperty, RowName);

Stack.StepCompiledIn<FStructProperty>(NULL); void* OutRowPtr = Stack.MostRecentPropertyAddress;

P_FINISH; bool bSuccess = false; // The following line fails to find the StructProp. See notes below this code block for the specifics. FStructProperty* StructProp = CastField<FStructProperty>(Stack.MostRecentProperty); if (!Table) { FBlueprintExceptionInfo ExceptionInfo( EBlueprintExceptionType::AccessViolation, NSLOCTEXT("GetDataTableRow", "MissingTableInput", "Failed to resolve the table input. Be sure the DataTable is valid.") ); FBlueprintCoreDelegates::ThrowScriptException(P_THIS, Stack, ExceptionInfo); } else if(StructProp && OutRowPtr) { UScriptStruct* OutputType = StructProp->Struct; const UScriptStruct* TableType = Table->GetRowStruct();

const bool bCompatible = (OutputType == TableType) || (OutputType->IsChildOf(TableType) &&
FStructUtils::TheSameLayout(OutputType, TableType)); if (bCompatible) {
P_NATIVE_BEGIN; bSuccess = Generic_GetDataTableRowFromName(Table, RowName, OutRowPtr); P_NATIVE_END; } else { FBlueprintExceptionInfo ExceptionInfo(
EBlueprintExceptionType::AccessViolation, NSLOCTEXT("GetDataTableRow", "IncompatibleProperty", "Incompatible output parameter; the data table's type is not the same as the return type.") ); FBlueprintCoreDelegates::ThrowScriptException(P_THIS, Stack, ExceptionInfo); } } else { FBlueprintExceptionInfo ExceptionInfo( EBlueprintExceptionType::AccessViolation,

NSLOCTEXT("GetDataTableRow", "MissingOutputProperty", "Failed to resolve the output parameter for GetDataTableRow.") ); FBlueprintCoreDelegates::ThrowScriptException(P_THIS, Stack, ExceptionInfo);
} *(bool*)RESULT_PARAM = bSuccess; }

The issue is that the Stack.MostRecentProperty does not get populated when we call the GetDataTableRowFromName() from a C++ context. This specifics of this have been documented at by the following GitHub issues:
Issue 1 (CN) Issue 2 (CN)
Under the hood:
static bool GetDataTableRowFromName (
UDataTable * Table, FName RowName, FTableRowBase & OutRow )
// Does some property reading, type checking, etc, // Then internally it calls
static bool Generic_GetDataTableRowFromName (
const UDataTable * Table, FName RowName, void * OutRowPtr )
It would be suitable for us to use a void* for the OutRow instead of a ref FTableRowBase , but as fate would have it, this Generic_GetDataTableRowFromName() is not accessible via reflection.
The core of the problem is that the execGetDataTableRowFromName() is particularly aggressive at typechecking and ensuring that the function will work or gracefully exit. This is expected since this function is a blueprint node and needs to be a robust function to work within the blueprint framework. The specific way that Stack.MostRecentProperty is used is to determine the target type of Struct that we expect to retrieve from the DataTable. In the blueprint caller context, this property would be populated as part of the Kismet FFrame/Stack pipeline.
Anything we can do?

I am currently playing with manually setting the Stack.MostRecentProperty to trick the GetDataTableRowFromName() into thinking that we’re calling the function as part of a legal blueprint function and not directly from C++ code. Like solution 1, I rate this solution as a probably? in the functionality department.

One final wrench in the machine…
There’s also further research needed about how DataTable row structs are stored in memory. It appears some games might have compiler packing, but the extent of this is still unknown. Furthermore, some games have reasonably laid out struct members for memory footprint/alignment/padding purposes, and other games have their struct members in a way that makes sense from a readability standpoint, but not from a memory optimization standpoint.

// NameTypes.hpp (UE4SS)

// TODO: Figure out what's going on here

//

It shouldn't be required to use 'alignas' here to

make sure it's aligned properly in containers (like TArray)

//

I've never seen an FName not be 8-byte aligned in

memory,

//

but it is 4-byte aligned in the source so hopefully

this doesn't cause any problems

// UPDATE: This matters in the UE VM, when ElementSize is 0xC

in memory for case-preserving games, it must be aligned by 0x4

in that case

#pragma warning(disable: 4324) // Suppressing warning about

struct alignment

#ifdef WITH_CASE_PRESERVING_NAME

struct alignas(4) RC_UE_API FName

#else

struct alignas(8) RC_UE_API FName // FNames in DataTable

rows seem to only work with alignas(4)

The above code is a TODO: that’s still in UE4SS. The investigation of alignment will likely have benefits across other non-DataTable parts! We’ll need to understand the full extent of alignment/padding regardless of which solution we use (TMap or Blueprint Library or Other).

Disclaimer
While I feel that I have a good understanding of the factors at play, I have no doubt that I’ve missed some of the nuance and have misunderstood parts of the underlying systems. Please let me know if you think

something operates differently than is currently documented. I would really appreciate the help!

Got any ideas?
Please reach out in the UE4SS Discord to brainstorm/share any ideas you might have. While I am currently in the role as feature lead for DataTables, I appreciate all the help I can get.

Other Resources
DataTable Pull Request - I think you need Epic Games group access to view this? UE5 Wiki (CN) UE4SS Docs JIP Blog

Credits
Special thanks to localcc for being a wonderful mentor. Shout out to all early adopters of the DataTable branches (special thanks to El for being our first early adopter).
Thanks for your continued patience.
– bitonality
