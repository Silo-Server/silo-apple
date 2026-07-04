//
//  FFmpegLogFilter.h
//  Continuum
//
//  Installs an `av_log_set_callback` that drops a small allowlist of known-
//  cosmetic warnings, collapses consecutive duplicate lines, and forwards
//  the rest to two sinks: stderr (tvOS `devicectl --console`, Xcode) and,
//  for warnings and errors, the unified log (subsystem = bundle id,
//  category "ffmpeg") so libav* diagnostics survive into Console.app and
//  sysdiagnose on shipped builds. The default FFmpeg callback emits
//  warnings for every probe-time codec parameter we *deliberately*
//  skipped (subtitle streams marked AVDISCARD_ALL pre-`find_stream_info`)
//  and for every TrueHD bitstream gripe during pre-prime, both of which
//  recover automatically. Suppressing them keeps the player log readable
//  without losing genuine errors.
//

#ifndef FFmpegLogFilter_h
#define FFmpegLogFilter_h

#ifdef __cplusplus
extern "C" {
#endif

/// Replaces the default `av_log` callback with one that drops the noise
/// patterns documented in the .m file. Idempotent — safe to call from any
/// thread, but normally called once at app launch.
void ContinuumInstallFFmpegLogFilter(void);

#ifdef __cplusplus
}
#endif

#endif /* FFmpegLogFilter_h */
