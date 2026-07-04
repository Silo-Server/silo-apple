//
//  FFmpegLogFilter.m
//  Continuum
//
//  See FFmpegLogFilter.h for context. Patterns dropped here:
//
//    "Could not find codec parameters for stream N (Subtitle: …)"
//      DVSegmentWriter and AVPlayerEmbeddedSubtitleExtractor both mark every
//      stream we will not decode (PGS subs, sidecar codecs, etc.) with
//      AVDISCARD_ALL before `find_stream_info`. The libavformat probe still
//      walks them looking for codec parameters it cannot fill, and warns
//      once per stream — once per probe context. With ~60 embedded subs
//      that is 100+ lines per session start. None of it is actionable.
//
//    "[truehd @ …] too many audio samples in frame"
//    "[truehd @ …] substream 0 length mismatch"
//    "[truehd @ …] restart header sync incorrect"
//    "[truehd @ …] Invalid blocksize"
//    "[truehd @ …] Lossless check failed"
//    "[truehd @ …] No samples to output"
//      The TrueHD decoder spits these out while it synchronises on the
//      first major_sync access unit. The DVSegmentWriter prime now skips
//      pending audio packets until a major_sync is found, but a small
//      tail can still trigger one or two of these on session start as the
//      bitstream parser realigns. They are cosmetic — playback recovers
//      with the next decoded frame.
//
//  Everything that survives the allowlist goes to two sinks:
//
//    - stderr, unchanged — tvOS `devicectl --console` and Xcode capture it.
//    - the unified log (subsystem = bundle id, category "ffmpeg") for
//      warnings and errors, so libav* diagnostics survive into Console.app
//      and sysdiagnose on shipped builds, where stderr is not collected.
//
//  Consecutive duplicate lines are collapsed into a single "repeated N
//  times" notice. FFmpeg's own AV_LOG_SKIP_REPEATED flag is a documented
//  no-op once a custom callback is installed, and a decode-error storm
//  otherwise floods both sinks. The `print_prefix` state persists across
//  calls (libav* emits multi-part lines without a trailing newline), which
//  is also why the whole callback serialises on one lock — `av_log` fires
//  from every FFmpeg thread.
//

#import "FFmpegLogFilter.h"

#import <Foundation/Foundation.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>

#import <Libavutil/log.h>

static os_unfair_lock continuum_log_lock = OS_UNFAIR_LOCK_INIT;
static os_log_t continuum_ffmpeg_log;
static int continuum_print_prefix = 1;
static char continuum_last_line[2048];
static unsigned continuum_repeat_count = 0;

/// Forward one formatted line to both sinks. Caller holds the lock.
static void continuum_emit(const char *line, int level) {
    if (continuum_ffmpeg_log != NULL && level <= AV_LOG_WARNING) {
        os_log_type_t type = (level <= AV_LOG_ERROR)
            ? OS_LOG_TYPE_ERROR
            : OS_LOG_TYPE_DEFAULT;
        os_log_with_type(continuum_ffmpeg_log, type, "%{public}s", line);
    }
    fputs(line, stderr);
}

static void continuum_av_log_callback(void *avcl, int level, const char *fmt, va_list vl) {
    if (level > av_log_get_level()) {
        return;
    }

    os_unfair_lock_lock(&continuum_log_lock);

    char line[2048];
    int written = av_log_format_line2(avcl, level, fmt, vl, line, sizeof(line), &continuum_print_prefix);
    if (written <= 0) {
        os_unfair_lock_unlock(&continuum_log_lock);
        return;
    }

    if (strstr(line, "Could not find codec parameters") != NULL) {
        os_unfair_lock_unlock(&continuum_log_lock);
        return;
    }

    if (strstr(line, "[truehd @ ") != NULL) {
        if (strstr(line, "too many audio samples") != NULL ||
            strstr(line, "substream 0 length mismatch") != NULL ||
            strstr(line, "restart header sync incorrect") != NULL ||
            strstr(line, "Invalid blocksize") != NULL ||
            strstr(line, "Lossless check failed") != NULL ||
            strstr(line, "No samples to output") != NULL) {
            os_unfair_lock_unlock(&continuum_log_lock);
            return;
        }
    }

    if (strcmp(line, continuum_last_line) == 0) {
        continuum_repeat_count += 1;
        os_unfair_lock_unlock(&continuum_log_lock);
        return;
    }
    if (continuum_repeat_count > 0) {
        char notice[64];
        snprintf(notice, sizeof(notice),
                 "    Last message repeated %u times\n", continuum_repeat_count);
        continuum_emit(notice, level);
        continuum_repeat_count = 0;
    }
    strlcpy(continuum_last_line, line, sizeof(continuum_last_line));
    continuum_emit(line, level);

    os_unfair_lock_unlock(&continuum_log_lock);
}

void ContinuumInstallFFmpegLogFilter(void) {
    const char *subsystem = NSBundle.mainBundle.bundleIdentifier.UTF8String;
    continuum_ffmpeg_log = os_log_create(
        subsystem != NULL ? subsystem : "org.siloserver.silo",
        "ffmpeg"
    );
    av_log_set_callback(continuum_av_log_callback);
}
