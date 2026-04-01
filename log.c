#include "log.h"
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <syslog.h>

static int use_syslog_backend = 0;
int sdh_log_debug_enabled = 0;

void sdh_log_init(int use_syslog)
{
    use_syslog_backend = use_syslog;
    if (use_syslog)
        openlog("sdh-proxy", LOG_PID, LOG_DAEMON);
}

void sdh_log(int level, const char *fmt, ...)
{
    if (level == SDH_LOG_DEBUG && !sdh_log_debug_enabled)
        return;

    va_list args;
    va_start(args, fmt);

    if (use_syslog_backend)
    {
        int prio;
        switch (level)
        {
            case SDH_LOG_ERROR: prio = LOG_ERR; break;
            case SDH_LOG_DEBUG: prio = LOG_DEBUG; break;
            default:            prio = LOG_INFO; break;
        }
        vsyslog(prio, fmt, args);
    }
    else
    {
        time_t now = time(NULL);
        struct tm *t = localtime(&now);
        const char *prefix;
        FILE *out;
        switch (level)
        {
            case SDH_LOG_ERROR: prefix = "ERROR"; out = stderr; break;
            case SDH_LOG_DEBUG: prefix = "DEBUG"; out = stdout; break;
            default:            prefix = "INFO";  out = stdout; break;
        }
        fprintf(out, "[%04d-%02d-%02d %02d:%02d:%02d] %s: ",
                t->tm_year + 1900, t->tm_mon + 1, t->tm_mday,
                t->tm_hour, t->tm_min, t->tm_sec, prefix);
        vfprintf(out, fmt, args);
        fprintf(out, "\n");
    }

    va_end(args);
}

void sdh_log_cleanup(void)
{
    if (use_syslog_backend)
        closelog();
}
