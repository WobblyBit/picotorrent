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
    int32_t  sequential;
} pt_status;

typedef struct pt_file
{
    char     path[512];
    int64_t  size;
    int64_t  done;
    int32_t  priority;      /* 0 = skip, 4 = normal, 7 = top */
} pt_file;

const char *pt_version(void);

pt_session *pt_session_new(void);
void        pt_session_free(pt_session *s);

/* 0 on success; on failure a message is written to err. */
int pt_add_torrent_file(pt_session *s, const char *path, const char *save_path, char *err, int errlen);
/* Reads a .torrent without adding it: name and files. Returns the file count, or -1 (message in err). */
int pt_peek(const char *path, char *name, int namelen, pt_file *out, int max, char *err, int errlen);
/* As pt_add_torrent_file, with one priority per file (0 = skip); nprio may be 0 for all files. */
int pt_add_torrent_file_ex(pt_session *s, const char *path, const char *save_path, const int32_t *prio, int nprio, char *err, int errlen);
int pt_add_magnet(pt_session *s, const char *uri, const char *save_path, char *err, int errlen);

int pt_torrent_count(pt_session *s);
int pt_torrent_status(pt_session *s, int index, pt_status *out);

void pt_pause(pt_session *s, int index);
void pt_resume(pt_session *s, int index);
void pt_recheck(pt_session *s, int index);
/* The handle is dropped from the list: later indexes shift down by one. */
void pt_remove(pt_session *s, int index, int delete_files);

int pt_dht_nodes(pt_session *s);

typedef struct pt_settings
{
    int32_t listen_port;
    int32_t down_limit;        /* bytes/s, 0 = unlimited */
    int32_t up_limit;
    int32_t dht;
    int32_t lsd;
    int32_t nat;               /* UPnP and NAT-PMP */
    int32_t proxy_type;        /* 0 none, 1 SOCKS5, 2 HTTP */
    int32_t proxy_port;
    int32_t active_downloads;  /* queue limits, 0 = unlimited */
    int32_t active_seeds;
    char    proxy_host[128];
} pt_settings;

void pt_apply_settings(pt_session *s, const pt_settings *st);

/* Hashes a file or folder into a .torrent at out_path. version: 1 = v1, 2 = v2, 3 = hybrid.
   trackers: one URL per line (may be empty). Needs no session; safe to call from a thread. 0 on success. */
int pt_create(const char *source, const char *out_path, int version, int is_private, const char *comment, const char *trackers, char *err, int errlen);

/* more per-torrent actions */
void pt_queue_move(pt_session *s, int index, int where);   /* 0 up, 1 down, 2 top, 3 bottom */
void pt_set_sequential(pt_session *s, int index, int on);
void pt_set_limits(pt_session *s, int index, int down_bps, int up_bps);   /* 0 = unlimited */
void pt_force_announce(pt_session *s, int index);
/* Magnet link of the torrent, or empty. */
int  pt_magnet(pt_session *s, int index, char *out, int outlen);
/* Writes the .torrent to path; 0 on success. */
int  pt_export(pt_session *s, int index, const char *path);


/* ---- details of one torrent (by index) ---- */

typedef struct pt_peer
{
    char     ip[64];
    char     client[64];
    int32_t  down_rate;
    int32_t  up_rate;
    float    progress;
    int32_t  incoming;
} pt_peer;

typedef struct pt_tracker
{
    char     url[256];
    char     message[128];  /* the last error or message; empty if fine */
    int32_t  tier;
    int32_t  fails;
    int32_t  working;
} pt_tracker;

/* Each returns how many entries it wrote (at most max). Files is empty until the metadata is known. */
int pt_files(pt_session *s, int index, pt_file *out, int max);
int pt_peers(pt_session *s, int index, pt_peer *out, int max);
int pt_trackers(pt_session *s, int index, pt_tracker *out, int max);

#ifdef __cplusplus
}
#endif
#endif
