#!/usr/bin/env bash

# This file is leveraged from the corefx report
# Some content such as anything related to building "native"
# Does not apply to WCF and is therefore a no op

usage()
{
    echo "Usage: $0 [managed] [native] [BuildArch] [BuildType] [clean] [verbose] [clangx.y] [platform] [cross]"
    echo "managed - optional argument to build the managed code"
    echo "native - optional argument to build the native code"
    echo "The following arguments affect native builds only:"
    echo "BuildArch can be: x64, x86, arm, arm64"
    echo "BuildType can be: Debug, Release"
    echo "clean - optional argument to force a clean build."
    echo "verbose - optional argument to enable verbose build output."
    echo "clangx.y - optional argument to build using clang version x.y."
    echo "platform can be: FreeBSD, Linux, NetBSD, OSX, Windows"
    echo "cross - optional argument to signify cross compilation,"
    echo "      - will use ROOTFS_DIR environment variable if set."
    exit 1
}

setup_dirs()
{
    echo Setting up directories for build

    mkdir -p "$__BinDir"
    mkdir -p "$__IntermediatesDir"
}

# Performs "clean build" type actions (deleting and remaking directories)

clean()
{
    echo "Cleaning previous output for the selected configuration"
    rm -rf "$__BinDir"
    rm -rf "$__IntermediatesDir"
    setup_dirs
}

# Check the system to ensure the right pre-reqs are in place

check_managed_prereqs()  
{  
    __monoversion=$(mono --version | grep "version 4.[1-9]")  
  
    if [ $? -ne 0 ]; then  
        # if built from tarball, mono only identifies itself as 4.0.1  
        __monoversion=$(mono --version | egrep "version 4.0.[1-9]+(.[0-9]+)?")  
        if [ $? -ne 0 ]; then  
            echo "Mono 4.0.1.44 or later is required to build corefx. Please see https://github.com/dotnet/corefx/blob/master/Documentation/building/unix-instructions.md for more details."  
            exit 1  
        else  
            echo "WARNING: Mono 4.0.1.44 or later is required to build corefx. Unable to assess if current version is supported."  
        fi  
    fi  
  
    if [ ! -e "$__referenceassemblyroot/.NETPortable" ]; then  
        echo "PCL reference assemblies not found. Please see https://github.com/dotnet/corefx/blob/master/Documentation/building/unix-instructions.md for more details."  
        exit 1  
    fi  
}  

check_native_prereqs()
{
    echo "Checking pre-requisites..."

    # Check presence of CMake on the path
    hash cmake 2>/dev/null || { echo >&2 "Please install cmake before running this script"; exit 1; }

    # Check for clang
    hash clang-$__ClangMajorVersion.$__ClangMinorVersion 2>/dev/null ||  hash clang$__ClangMajorVersion$__ClangMinorVersion 2>/dev/null ||  hash clang 2>/dev/null || { echo >&2 "Please install clang before running this script"; exit 1; }
}

# Prepare the system for building

prepare_managed_build()
{
    # Pull NuGet.exe down if we don't have it already
    if [ ! -e "$__nugetpath" ]; then
        which curl wget > /dev/null 2> /dev/null
        if [ $? -ne 0 -a $? -ne 1 ]; then
            # *** start WCF Content ***
            echo "cURL or wget is required to build wcf. Please see https://github.com/dotnet/wcf/blob/master/Documentation/building/unix-instructions.md for more details."
            # *** end WCF Content ***
            exit 1
        fi
        echo "Restoring NuGet.exe..."

        # curl has HTTPS CA trust-issues less often than wget, so lets try that first.
        which curl > /dev/null 2> /dev/null
        if [ $? -ne 0 ]; then
           mkdir -p $__packageroot
           wget -q -O $__nugetpath https://api.nuget.org/downloads/nuget.exe
        else
           curl -sSL --create-dirs -o $__nugetpath https://api.nuget.org/downloads/nuget.exe
        fi

        if [ $? -ne 0 ]; then
            echo "Failed to restore NuGet.exe."
            exit 1
        fi
    fi

	    # Grab the MSBuild package if we don't have it already  
    if [ ! -e "$__msbuildpath" ]; then  
        echo "Restoring MSBuild..."  
        mono "$__nugetpath" install $__msbuildpackageid -Version $__msbuildpackageversion -source "https://www.myget.org/F/dotnet-buildtools/" -OutputDirectory "$__packageroot"  
        if [ $? -ne 0 ]; then  
            echo "Failed to restore MSBuild."  
            exit 1  
        fi  
    fi  

    # Run Init-Tools to restore BuildTools and ToolRuntime
    $__scriptpath/init-tools.sh
}

prepare_native_build()
{
    # Specify path to be set for CMAKE_INSTALL_PREFIX.
    # This is where all built CoreClr libraries will copied to.
    export __CMakeBinDir="$__BinDir"

    # Configure environment if we are doing a clean build.
    if [ $__CleanBuild == 1 ]; then
        clean
    fi

    # Configure environment if we are doing a verbose build
    if [ $__VerboseBuild == 1 ]; then
        export VERBOSE=1
    fi
}

build_managed_corefx()
{
    __buildproj=$__scriptpath/build.proj
    __buildlog=$__scriptpath/msbuild.log
    __binclashlog=$__scriptpath/binclash.log
    __binclashloggerdll=$__scriptpath/Tools/Microsoft.DotNet.Build.Tasks.dll

    # Reverting to prior version of msbuild
    # MONO29679=1 
    ReferenceAssemblyRoot=$__referenceassemblyroot mono $__msbuildpath "$__buildproj" /nologo /verbosity:minimal "/fileloggerparameters:Verbosity=normal;LogFile=$__buildlog" /t:Build /p:OSGroup=$__BuildOS /p:COMPUTERNAME=$(hostname) /p:USERNAME=$(id -un) /p:TestNugetRuntimeId=$__TestNugetRuntimeId /p:ToolNugetRuntimeId=$__TestNugetRuntimeId $__UnprocessedBuildArgs
    # $__scriptpath/Tools/corerun $__scriptpath/Tools/MSBuild.exe "$__buildproj" /nologo /verbosity:minimal "/fileloggerparameters:Verbosity=normal;LogFile=$__buildlog" "/l:BinClashLogger,$__binclashloggerdll;LogFile=$__binclashlog" /t:Build /p:ConfigurationGroup=$__BuildType /p:OSGroup=$__BuildOS /p:COMPUTERNAME=$(hostname) /p:USERNAME=$(id -un) /p:TestNugetRuntimeId=$__TestNugetRuntimeId $__UnprocessedBuildArgs
    BUILDERRORLEVEL=$?

    echo

    # Pull the build summary from the log file
    tail -n 4 "$__buildlog"
    echo Build Exit Code = $BUILDERRORLEVEL
}

build_native_corefx()
{
    # All set to commence the build

    echo "Commencing build of corefx native components for $__BuildOS.$__BuildArch.$__BuildType"
    cd "$__IntermediatesDir"

    # Regenerate the CMake solution
    echo "Invoking cmake with arguments: \"$__nativeroot\" $__CMakeArgs"
    "$__nativeroot/gen-buildsys-clang.sh" "$__nativeroot" $__ClangMajorVersion $__ClangMinorVersion $__BuildArch $__CMakeArgs

    # Check that the makefiles were created.

    if [ ! -f "$__IntermediatesDir/Makefile" ]; then
        echo "Failed to generate native component build project!"
        exit 1
    fi

    # Get the number of processors available to the scheduler
    # Other techniques such as `nproc` only get the number of
    # processors available to a single process.
    if [ `uname` = "FreeBSD" ]; then
        NumProc=`sysctl hw.ncpu | awk '{ print $2+1 }'`
    elif [ `uname` = "NetBSD" ]; then
        NumProc=$(($(getconf NPROCESSORS_ONLN)+1))
    else
        NumProc=$(($(getconf _NPROCESSORS_ONLN)+1))
    fi

    # Build

    echo "Executing make install -j $NumProc"

    make install -j $NumProc
    if [ $? != 0 ]; then
        echo "Failed to build corefx native components."
        exit 1
    fi

    echo "CoreFX native components successfully built."
    echo "Product binaries are available at $__BinDir"
}

__scriptpath=$(cd "$(dirname "$0")"; pwd -P)
__nativeroot=$__scriptpath/src/Native
__packageroot=$__scriptpath/packages
__sourceroot=$__scriptpath/src
__nugetpath=$__packageroot/NuGet.exe
__nugetconfig=$__sourceroot/NuGet.Config
__rootbinpath="$__scriptpath/bin"
__msbuildpackageid="Microsoft.Build.Mono.Debug"
__msbuildpackageversion="14.1.0.0-prerelease"
__msbuildpath=$__packageroot/$__msbuildpackageid.$__msbuildpackageversion/lib/MSBuild.exe
__buildmanaged=false
__buildnative=false
__TestNugetRuntimeId=win7-x64

# Use uname to determine what the CPU is.
CPUName=$(uname -p)
# Some Linux platforms report unknown for platform, but the arch for machine.
if [ $CPUName == "unknown" ]; then
    CPUName=$(uname -m)
fi

case $CPUName in
    i686)
        __BuildArch=x86
        ;;

    x86_64)
        __BuildArch=x64
        ;;

    armv7l)
        __BuildArch=arm
        ;;

    aarch64)
        __BuildArch=arm64
        ;;

    *)
        echo "Unknown CPU $CPUName detected, configuring as if for x64"
        __BuildArch=x64
        ;;
esac

# Use uname to determine what the OS is.
OSName=$(uname -s)
case $OSName in
    Darwin)
        __HostOS=OSX
        __TestNugetRuntimeId=osx.10.10-x64
        ;;

    FreeBSD)
        __HostOS=FreeBSD
        # TODO: Add native version
        __TestNugetRuntimeId=osx.10.10-x64
        ;;

    Linux)
        __HostOS=Linux
        source /etc/os-release
        if [ "$ID" == "centos" ]; then
            __TestNugetRuntimeId=centos.7-x64
        elif [ "$ID" == "rhel" ]; then
            __TestNugetRuntimeId=rhel.7-x64
        elif [ "$ID" == "ubuntu" ]; then
            __TestNugetRuntimeId=ubuntu.14.04-x64
        elif [ "$ID" == "debian" ]; then
            __TestNugetRuntimeId=debian.8-x64
        else
            echo "Unsupported Linux distribution '$ID' detected. Configuring as if for Ubuntu."
            __TestNugetRuntimeId=ubuntu.14.04-x64
        fi
        ;;

    NetBSD)
        __HostOS=NetBSD
        # TODO: Add native version
        __TestNugetRuntimeId=osx.10.10-x64
        ;;

    *)
        echo "Unsupported OS '$OSName' detected. Configuring as if for Ubuntu."
        __HostOS=Linux
        __TestNugetRuntimeId=ubuntu.14.04-x64
        ;;
esac
__BuildOS=$__HostOS
__BuildType=Debug
__CMakeArgs=DEBUG

case $__HostOS in  
    FreeBSD)  
        __monoroot=/usr/local  
        ;;  
    OSX)  
        __monoroot=/Library/Frameworks/Mono.framework/Versions/Current  
        ;;  
    *)  
        __monoroot=/usr  
        ;;  
esac  
  
__referenceassemblyroot=$__monoroot/lib/mono/xbuild-frameworks  
BUILDERRORLEVEL=0

# Set the various build properties here so that CMake and MSBuild can pick them up
__UnprocessedBuildArgs=
__CleanBuild=false
__CrossBuild=0
__VerboseBuild=false
__ClangMajorVersion=3
__ClangMinorVersion=5

for i in "$@"
    do
        lowerI="$(echo $i | awk '{print tolower($0)}')"
        case $lowerI in
        -?|-h|--help)
            usage
            exit 1
            ;;
        managed)
            __buildmanaged=true
            ;;
        native)
            __buildnative=true
            ;;
        x86)
            __BuildArch=x86
            ;;

        x64)
            __BuildArch=x64
            ;;

        arm)
            __BuildArch=arm
            ;;

        arm64)
            __BuildArch=arm64
            ;;

        debug)
            __BuildType=Debug
            ;;
        release)
            __BuildType=Release
            __CMakeArgs=RELEASE
            ;;
        clean)
            __CleanBuild=1
            ;;
        verbose)
            __VerboseBuild=1
            ;;
        clang3.5)
            __ClangMajorVersion=3
            __ClangMinorVersion=5
            ;;
        clang3.6)
            __ClangMajorVersion=3
            __ClangMinorVersion=6
            ;;
        clang3.7)
            __ClangMajorVersion=3
            __ClangMinorVersion=7
            ;;
        freebsd)
            __BuildOS=FreeBSD
            __TestNugetRuntimeId=osx.10.10-x64
            ;;
        linux)
            __BuildOS=Linux
            # If the Host OS is also Linux, then use the RID of the host.
            # Otherwise, override it to Ubuntu by default.
            if [ "$__HostOS" != "Linux" ]; then
                __TestNugetRuntimeId=ubuntu.14.04-x64
            fi
            ;;
        netbsd)
            __BuildOS=NetBSD
            __TestNugetRuntimeId=osx.10.10-x64
            ;;
        osx)
            __BuildOS=OSX
            __TestNugetRuntimeId=osx.10.10-x64
            ;;
        windows)
            __BuildOS=Windows_NT
            __TestNugetRuntimeId=win7-x64
            ;;
        cross)
            __CrossBuild=1
            ;;
        *)
          __UnprocessedBuildArgs="$__UnprocessedBuildArgs $i"
    esac
done

# If neither managed nor native are passed as arguments, default to building both

if [ "$__buildmanaged" = false -a "$__buildnative" = false ]; then
    __buildmanaged=true
    __buildnative=true
fi

# Disable the native build when targeting Windows.

if [ "$__BuildOS" != "$__HostOS" ]; then
    echo "Warning: cross compiling native components is not yet supported"
    __buildnative=false
fi

# Set the remaining variables based upon the determined build configuration
__IntermediatesDir="$__rootbinpath/obj/$__BuildOS.$__BuildArch.$__BuildType/Native"
__BinDir="$__rootbinpath/$__BuildOS.$__BuildArch.$__BuildType/Native"

# Make the directories necessary for build if they don't exist

setup_dirs

if $__buildmanaged; then

    # Check prereqs.  
  
    check_managed_prereqs 

    # Prepare the system

    prepare_managed_build

    # Build the corefx native components.

    build_managed_corefx

    # Build complete
fi

# If managed build failed, exit with the status code of the managed build
if [ $BUILDERRORLEVEL != 0 ]; then
    exit $BUILDERRORLEVEL
fi

# Configure environment if we are doing a cross compile.
if [ "$__CrossBuild" == 1 ]; then
    export CROSSCOMPILE=1
    if ! [[ -n "$ROOTFS_DIR" ]]; then
        export ROOTFS_DIR="$__scriptpath/cross/rootfs/$__BuildArch"
    fi
fi

if $__buildnative; then

    # Check prereqs.

    check_native_prereqs

    # Prepare the system

    prepare_native_build

    # Build the corefx native components.
    # *** start WCF Content ***

    # WCF does not have a native component, comment out next command
    # build_native_corefx
    
    # *** end WCF Content ***

    # Build complete
fi

exit $BUILDERRORLEVEL
