#include "config.h"
#include "sdh-proxy.h"
#include "timer.h"
#include "log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

extern char *iface_list[];
extern int num_ifaces;
extern int use_all_interfaces;
extern char *port_list[];
extern int num_ports;
extern int debug;
extern int logstat;
extern int sdh_log_debug_enabled;

typedef enum {
    SECTION_NONE,
    SECTION_INTERFACES,
    SECTION_PORTS,
    SECTION_SETTINGS
} config_section_t;

/* Strip leading whitespace, returning pointer into the same buffer */
static char *strip_leading(char *s)
{
    while (*s && isspace((unsigned char)*s))
        s++;
    return s;
}

/* Strip trailing whitespace in-place */
static void strip_trailing(char *s)
{
    char *end = s + strlen(s) - 1;
    while (end >= s && isspace((unsigned char)*end))
        *end-- = '\0';
}

static int parse_yes_no(const char *val)
{
    if (strcmp(val, "yes") == 0)
        return 1;
    if (strcmp(val, "no") == 0)
        return 0;
    return -1;
}

int sdh_config_load(const char *path)
{
    FILE *fp = fopen(path, "r");
    if (!fp)
    {
        sdh_log(SDH_LOG_ERROR, "Cannot open config file: %s", path);
        return -1;
    }

    char line[256];
    config_section_t section = SECTION_NONE;
    int lineno = 0;

    while (fgets(line, sizeof(line), fp) != NULL)
    {
        lineno++;

        /* Strip comments */
        char *comment = strchr(line, '#');
        if (comment)
            *comment = '\0';

        /* Strip whitespace */
        char *p = strip_leading(line);
        strip_trailing(p);

        /* Skip empty lines */
        if (*p == '\0')
            continue;

        /* Check for section header */
        if (*p == '[')
        {
            if (strcmp(p, "[interfaces]") == 0)
                section = SECTION_INTERFACES;
            else if (strcmp(p, "[ports]") == 0)
                section = SECTION_PORTS;
            else if (strcmp(p, "[settings]") == 0)
                section = SECTION_SETTINGS;
            else
            {
                sdh_log(SDH_LOG_ERROR, "Config line %d: unknown section: %s", lineno, p);
                fclose(fp);
                return -1;
            }
            continue;
        }

        switch (section)
        {
        case SECTION_INTERFACES:
            if (strcmp(p, "auto") == 0)
            {
                use_all_interfaces = 1;
            }
            else
            {
                if (num_ifaces >= MAX_IFACES)
                {
                    sdh_log(SDH_LOG_ERROR, "Config line %d: too many interfaces (max %d)", lineno, MAX_IFACES);
                    fclose(fp);
                    return -1;
                }
                iface_list[num_ifaces] = malloc(strlen(p) + 1);
                strcpy(iface_list[num_ifaces], p);
                num_ifaces++;
            }
            break;

        case SECTION_PORTS:
            if (num_ports >= MAX_PORTS)
            {
                sdh_log(SDH_LOG_ERROR, "Config line %d: too many ports (max %d)", lineno, MAX_PORTS);
                fclose(fp);
                return -1;
            }
            port_list[num_ports] = malloc(strlen(p) + 1);
            strcpy(port_list[num_ports], p);
            num_ports++;
            break;

        case SECTION_SETTINGS:
        {
            /* key = value parsing */
            char *eq = strchr(p, '=');
            if (!eq)
            {
                sdh_log(SDH_LOG_ERROR, "Config line %d: expected key=value in [settings]", lineno);
                fclose(fp);
                return -1;
            }
            *eq = '\0';
            char *key = p;
            char *val = eq + 1;
            strip_trailing(key);
            val = strip_leading(val);
            strip_trailing(val);

            if (strcmp(key, "rate_limit") == 0)
            {
                int v = parse_yes_no(val);
                if (v < 0)
                {
                    sdh_log(SDH_LOG_ERROR, "Config line %d: rate_limit expects yes/no", lineno);
                    fclose(fp);
                    return -1;
                }
                timer_enabled = v;
            }
            else if (strcmp(key, "rate_limit_timeout") == 0)
            {
                int ms = atoi(val);
                if (ms <= 0)
                {
                    sdh_log(SDH_LOG_ERROR, "Config line %d: rate_limit_timeout must be a positive integer", lineno);
                    fclose(fp);
                    return -1;
                }
                pkt_timeout_s = ms / 1000;
                pkt_timeout_us = (ms % 1000) * 1000;
                timer_enabled = 1;
            }
            else if (strcmp(key, "log_stats") == 0)
            {
                int v = parse_yes_no(val);
                if (v < 0)
                {
                    sdh_log(SDH_LOG_ERROR, "Config line %d: log_stats expects yes/no", lineno);
                    fclose(fp);
                    return -1;
                }
                logstat = v;
            }
            else if (strcmp(key, "syslog") == 0)
            {
                int v = parse_yes_no(val);
                if (v < 0)
                {
                    sdh_log(SDH_LOG_ERROR, "Config line %d: syslog expects yes/no", lineno);
                    fclose(fp);
                    return -1;
                }
                if (v)
                    sdh_log_init(1);
            }
            else if (strcmp(key, "debug") == 0)
            {
                int v = parse_yes_no(val);
                if (v < 0)
                {
                    sdh_log(SDH_LOG_ERROR, "Config line %d: debug expects yes/no", lineno);
                    fclose(fp);
                    return -1;
                }
                debug = v;
                sdh_log_debug_enabled = v;
            }
            else
            {
                sdh_log(SDH_LOG_ERROR, "Config line %d: unknown setting: %s", lineno, key);
                fclose(fp);
                return -1;
            }
            break;
        }

        case SECTION_NONE:
            sdh_log(SDH_LOG_ERROR, "Config line %d: data outside of section: %s", lineno, p);
            fclose(fp);
            return -1;
        }
    }

    fclose(fp);
    sdh_log(SDH_LOG_INFO, "Loaded config from %s", path);
    return 0;
}
