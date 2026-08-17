//
//  FFmpegLogFilter.m
//  Silo
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
//  Anything else is forwarded to stderr unchanged so genuine errors
//  remain visible.
//

#import "FFmpegLogFilter.h"

#import <stdarg.h>
#import <stdio.h>
#import <string.h>

#import <Libavutil/log.h>

static void silo_av_log_callback(void *avcl, int level, const char *fmt, va_list vl) {
    if (level > av_log_get_level()) {
        return;
    }

    char line[2048];
    int print_prefix = 1;
    int written = av_log_format_line2(avcl, level, fmt, vl, line, sizeof(line), &print_prefix);
    if (written <= 0) {
        return;
    }

    if (strstr(line, "Could not find codec parameters") != NULL) {
        return;
    }

    if (strstr(line, "[truehd @ ") != NULL) {
        if (strstr(line, "too many audio samples") != NULL ||
            strstr(line, "substream 0 length mismatch") != NULL ||
            strstr(line, "restart header sync incorrect") != NULL ||
            strstr(line, "Invalid blocksize") != NULL ||
            strstr(line, "Lossless check failed") != NULL ||
            strstr(line, "No samples to output") != NULL) {
            return;
        }
    }

    fputs(line, stderr);
}

void SiloInstallFFmpegLogFilter(void) {
    av_log_set_callback(silo_av_log_callback);
}
