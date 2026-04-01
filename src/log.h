#ifndef SDH_LOG_H
#define SDH_LOG_H

#define SDH_LOG_ERROR 0
#define SDH_LOG_INFO  1
#define SDH_LOG_DEBUG 2

void sdh_log_init(int use_syslog);
void sdh_log(int level, const char *fmt, ...);
void sdh_log_cleanup(void);

extern int sdh_log_debug_enabled;

#endif
