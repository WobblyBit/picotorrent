/* PicoTorrent for Linux: a thin C ABI over libtorrent-rasterbar, called from Odin. */
#ifndef PT_LT_H
#define PT_LT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pt_session pt_session;

typedef struct pt_status
{
    char     name[256];
    char     hash_v1[41];   /* empty if the torrent has no v1 hash */
    char     hash_v2[65];   /* empty if the torrent has no v2 hash */
    int32_t  state;         /* libtorrent torrent_status::state_t */
    int32_t  paused;
    float    progress;      /* 0..1 */
    int64_t  total_wanted;
    int64_t  total_done;
    int32_t  num_peers;
    int32_t  num_seeds;
} pt_status;

const char *pt_version(void);

pt_session *pt_session_new(void);
void        pt_session_free(pt_session *s);

/* 0 on success; on failure a message is written to err. */
int pt_add_torrent_file(pt_session *s, const char *path, const char *save_path, char *err, int errlen);
int pt_add_magnet(pt_session *s, const char *uri, const char *save_path, char *err, int errlen);

int pt_torrent_count(pt_session *s);
int pt_torrent_status(pt_session *s, int index, pt_status *out);

#ifdef __cplusplus
}
#endif
#endif
