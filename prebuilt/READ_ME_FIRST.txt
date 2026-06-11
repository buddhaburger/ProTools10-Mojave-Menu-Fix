This folder holds the pre-built fix files:

    CFD_release.dylib   (Recommended — fast and quiet)
    CFD_debug.dylib     (Troubleshooting — verbose log)

If this folder is EMPTY, build them first:
    cd ../source
    ./build.sh
The binaries will be created here automatically.

(For the public GitHub release, these two .dylib files are
included so users don't need Xcode.)
