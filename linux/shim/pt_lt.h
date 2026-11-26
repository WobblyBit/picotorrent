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
    char     save_path[512];
    char     error[128];
    int32_t  state;         /* libtorrent torrent_status::state_t */
    int32_t  paused;
    int32_t  auto_managed;  /* with paused: waiting in the queue, not paused by the user */
    int32_t  queue_position;
    int32_t  download_rate; /* bytes/s */
    int32_t  upload_rate;
    int32_t  num_peers;     /* connected */
    int32_t  num_seeds;
    int32_t  list_peers;    /* known in the swarm */
    int32_t  list_seeds;
    float    progress;      /* 0..1 */
    float    availability;
    int64_t  total_wanted;
    int64_t  total_done;
    int64_t  all_time_download;
    int64_t  all_time_upload;
    int64_t  added_time;    /* unix seconds */
    int64_t  completed_time;
} pt_status;

const char *pt_version(void);

pt_session *pt_session_new(void);
void        pt_session_free(pt_session *s);

/* 0 on success; on failure a message is written to err. */
int pt_add_torrent_file(pt_session *s, const char *path, const char *save_path, char *err, int errlen);
int pt_add_magnet(pt_session *s, const char *uri, const char *save_path, char *err, int errlen);

int pt_torrent_count(pt_session *s);
int pt_torrent_status(pt_session *s, int index, pt_status *out);

void pt_pause(pt_session *s, int index);
void pt_resume(pt_session *s, int index);
void pt_recheck(pt_session *s, int index);
/* The handle is dropped from the list: later indexes shift down by one. */
void pt_remove(pt_session *s, int index, int delete_files);

int pt_dht_nodes(pt_session *s);

#ifdef __cplusplus
}
#endif
#endif
