// ImportC-ready C wrapper for PipeWire.
//
// If the D toolchain supports ImportC, a D module can consume the real C API
// directly, e.g. (dub + ldc):
//
//     importPaths "src/audio/cimports"
//     import c_pipewire;  // maps to cimports/c_pipewire.h
//
// The header below is valid C99 and valid ImportC. It deliberately includes
// only what the engine needs so the ImportC surface stays small.
#ifndef OVSR_C_PIPEWIRE_H
#define OVSR_C_PIPEWIRE_H

#include <pipewire/pipewire.h>
#include <pipewire/filter.h>
#include <pipewire/thread-loop.h>
#include <pipewire/properties.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/audio/raw.h>

#endif
