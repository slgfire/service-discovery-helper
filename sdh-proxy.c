/*
 * Service Discovery Helper
 * For game server discovery across VLANs, and similar applications
 *
 * (c) Chris "SirSquidness" Holman, October 2013
 * Licensed under the MIT License license.
 * See LICENSE for more details
 *
 * Forwards UDP broadcasts on given ports out other interfaces on the system. 
 * Useful for discovering game (or other) servers on other VLANs. Makes sure 
 * not to send a broadcast back out the same interface. 
 *
 * Usage: 
 *  sudo ./sdh-proxy -a -p ports
 *  sudo ./sdh-proxy -i interfaces -p ports
 *  sudo ./sdh-proxy -i interfaces -p ports -d
 *  ./sdh-proxy -h
 *
 * Currently requires configuration to be hard coded. I'll fix that soon. 
 * (honest!). Edit the iface_list array to contain all interfaces you use.
 * Edit the filter_string example to include all UDP port numbers. 
 *
 * Requires root
 * Requires libpcap and the libpcap headers (libpcap-dev) to be installed.
 * 
 * Compile using:
 * gcc -g -std=gnu99 -o sdh-proxy sdh-proxy.c -lpcap -lpthread
 * (Makefile with this in it provided)
 */
#include "sdh-proxy.h"
#include <arpa/inet.h>
#include "timer.h"
#include "log.h"
#include "config.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <pcap.h>
#include <pthread.h>
#include <ctype.h>
#include <signal.h>

// For getuid() and geteuid()
#include <unistd.h>
#include <sys/types.h>


// List of interfaces. Later on, will make it input these as a file or arg
//char *iface_list[] = {"eth0", "eth1"};;
interface_data *iface_data;
char * iface_list[MAX_IFACES]; // This is kind of redundant; too late now.
int num_ifaces = 0;
int use_all_interfaces = 0;

// The list of ports from the input files get read in to this before 
// the filter string is made. 
char * port_list[MAX_PORTS];
int num_ports = 0;


// The PCAP/BPF filter string is stored in this. Generated in 
// generate_filter_string().
char * filter;

// To do: put in conditions for things to exito n
volatile sig_atomic_t do_exit = 0;

// Toggled with -d on command line. Displays debug info.
int debug = 0;

char *config_file = NULL;

// Toggled with -l on command line. Write Stats to stat.log
int logstat = 0;
char logstatfile[] = "sdh.stat";

// Does nothing at the moment. Will enable rewriting subnet info if relevant. 
int do_network_rewrite = 0; // Rewrite IP broadcast address for the new
                            // network interface
int64_t pkt_rx = 0;
int64_t pkt_tx = 0;
int64_t pkt_drop = 0;
uint32_t pkt_stats[65536];
int logtimer = 0;
  
/**
  * Calculate checksum for IP packet.
  * Taken from http://stackoverflow.com/a/7010971
  * No idea what the license for it is; public domain? Hopefully!
  *
  * This isn't currently used in code. I was fiddling around with it earlier. 
  * Leaving here for future reference. 
  *
  * @param ptr Pointer to the frame contents
  * @param nbytes How many bytes long the frame is
  * @return The checksum.
  */
unsigned short in_cksum(unsigned short *ptr, int nbytes) {

    register long sum; /* assumes long == 32 bits */
    u_short oddbyte;
    register u_short answer; /* assumes u_short == 16 bits */
    /*
     * the algorithm is simple, using a 32-bit accumulator (sum),
     * we add sequential 16-bit words to it, and at the end, fold back
     * all the carry bits from the top 16 bits into the lower 16 bits.
     */
    sum = 0;
    while (nbytes > 1) {
        sum += *ptr++;
        nbytes -= 2;
    }

    /* mop up an odd byte, if necessary */
    if (nbytes == 1) {
        oddbyte = 0; /* make sure top half is zero */
        *((u_char *) &oddbyte) = *(u_char *) ptr; /* one byte only */
        sum += oddbyte;
    }

    /*
     * Add back carry outs from top 16 bits to low 16 bits.
     */
    sum = (sum >> 16) + (sum & 0xffff); /* add high-16 to low-16 */
    sum += (sum >> 16); /* add carry */
    answer = ~sum; /* ones-complement, then truncate to 16 bits */
    return (answer);
}


unsigned short int * udp_get_port( const short unsigned int pktlen, const u_char *packet)
{

  const u_char udp_hdr_length = 4* ( *(packet+ETH_HDR_LENGTH) & UDP_NUM_HEADERS_MASK );
  if ( udp_hdr_length > pktlen - ETH_HDR_LENGTH)
  {
    sdh_log(SDH_LOG_ERROR, "Found packet that says it has more headers than the packet is long.");
    return NULL;
  }

  return  (unsigned short int *)
    ( 
     // Packet start, jump over the ethernet header
     packet + ETH_HDR_LENGTH + 
     // 32 bit headers (4 bytes)
     udp_hdr_length
     // Jump over source port to dest port (two bytes)
     + 2
    );

}

/** 
 * function to log some statistical Ouitput to a logfile
 * This is usefull to get somewhat of information / statistical logging.
 *

 *
 **/
void writeLogStats()
{
    // don't spam! just write the log once every X seconds
    if((logtimer + 10) < (int)time(NULL)) {
      FILE * fp;
      fp = fopen(logstatfile, "w+");
      if (fp) 
      {
        // General Stats
        fprintf(fp,"## GENERAL\nRX:%ld\nTX:%ld\nDROP:%ld\n## PORT STATS\n",(long) pkt_rx, (long) pkt_tx, (long) pkt_drop);
        // port based stats
        for (int i = 0; i < 65536; i++)
          if(pkt_stats[i] > 0)
            fprintf(fp,"%d:%u\n",i, pkt_stats[i]);
        
        // interface stats
        fprintf(fp,"## IFACE STATS\n");
        for (int i = 0; i < num_ifaces; i++)
          fprintf(fp,"%s:%ld\n",iface_list[i], (long) iface_data[i].num_packets);
        fclose(fp);
      }
      logtimer = (int)time(NULL);
    }
}
/**
 * Given a source interface name and a packet, flood that packet to every other
 * interface
 * 
 * @param args 
 * @param header The PCAP packet header (contains length of packet)
 * @param packet The packet to be flooded
 *
 **/
void flood_packet( u_char *source_iface, const struct pcap_pkthdr *header, const u_char *packet)
{
  int i;
  u_char * sendpacket;
  __sync_fetch_and_add(&pkt_rx, 1);
  sendpacket = malloc(header->len);
  // This memcpy is only to let me experiment with modifying the packet. 
  // Not neccessary if not modifying packet, but easier to leave here. 
  memcpy(sendpacket, packet, header->len);
  

  if (timer_enabled)
  {
    // Offset of IP address in an IP header
    const bpf_u_int32 * srcipaddr =  (const bpf_u_int32 *) (packet+26);
    
    // Remember, if using this printf, cast type to unsigned char *
    //  printf("%hhu.%hhu.%hhu.%hhu\n", *(srcipaddr +0 ) , *(srcipaddr +1 ) , *(srcipaddr +2 ) , *(srcipaddr +3 ) );
   
    unsigned short int * dstport =  udp_get_port(header->len, packet);
    //(unsigned short int *)( packet +14 + (4 * ( *(packet+14) & 0x0F) ) + 2) ;
    
    // Returns NULL if we can't figure out the dst port of the packet. 
    // And if we can't figure out the dest port, that probably means it's 
    // malicious or broken, so we don't care about it anyway
    if (dstport == NULL)
      return;

    if (logstat) {
        // some Port Statistics for each port
        __sync_fetch_and_add(&pkt_stats[ntohs(*dstport)], 1);
        // writing some logfile stats.
        writeLogStats();
    }

    // Check if this packet hits the rate limiter
    if (timer_check_packet(srcipaddr, dstport) == SEND_PACKET)
    {
      sdh_log(SDH_LOG_DEBUG, "SEND Packet port %hu addr %hhu.%hhu.%hhu.%hhu len %d bc %d.%d.%d.%d (RX: %ld TX: %ld DROP: %ld)", ntohs(*dstport), *(srcipaddr +0 ) , *(srcipaddr +1 ) , *(srcipaddr +2 ) , *(srcipaddr +3 ), header->len,sendpacket[30],sendpacket[31],sendpacket[32],sendpacket[33], (long) pkt_rx, (long) pkt_tx, (long) pkt_drop);
    }
    else
    {
      __sync_fetch_and_add(&pkt_drop, 1);
      sdh_log(SDH_LOG_DEBUG, "DROP Packet port %hu addr %hhu.%hhu.%hhu.%hhu len %d", ntohs(*dstport), *(srcipaddr +0 ) , *(srcipaddr +1 ) , *(srcipaddr +2 ) , *(srcipaddr +3 ), header->len);
      // TODO: increment packet_drop_count on iface data
      return;
    }
  }

  // Optionally rewrite the IP layer broadcast address to suit the new subnet
/*  if ( do_network_rewrite > 0)
  {
    // This resets the checksum to 0
    sendpacket[24] = 0x00;
    sendpacket[25] = 0x00;
    // Reset broadcast address to 255.255.255.255
    for (i = 30; i<34; i++)
      sendpacket[i] = 0xFF;
    // This isn't actually the packet checksum. One needs to create a pseudo 
    // header first; I'll do that later. 
    //printf("Packet checksum: %x\n", in_cksum((unsigned short *)sendpacket, header->len));
  }*/

  for (i = 0; i < num_ifaces; i++)
  {
    if (strcmp(iface_list[i], (const char *)source_iface) != 0)
    {
      pcap_inject(iface_data[i].pcap_int, sendpacket, header->len);

    }
    else
    {
      __sync_fetch_and_add(&iface_data[i].num_packets, 1);
    }
  }
  __sync_fetch_and_add(&pkt_tx, 1);

  // we only malloc() this if we're modifying the frame
  //if (do_network_rewrite>0)   // malloc() moved outisde conditional above
  free(sendpacket);
}

/** 
 * Starts listening for incoming broadcasts, and sends them to be dealt with
 * Thread entry point
 *
 * @param args: The struct contains the name of the interface and the pcap_t pointer
 *
 **/
void *  start_listening(void * args)
{
  const interface_data * iface_data = (interface_data *)args;

  sdh_log(SDH_LOG_INFO, "Thread spawned");
  while (1)
  {
    if (do_exit) break;
    // The 2 is how many packets to process in each loop. Not sure what best 
    // value to have here is
    pcap_loop(iface_data->pcap_int, 2, flood_packet, (u_char *)iface_data->interface);
  }
  return NULL;
}

/** 
 * Initialises a PCAP interface and applies the filters we need
 *
 * @param interface: The name of the interface to use
 **/
pcap_t * init_pcap_int ( const char * interface, char * errbuf)
{
  pcap_t * ret;
  struct bpf_program  fp;
  sdh_log(SDH_LOG_DEBUG, "Opening PCAP interface for %s", interface);

  // Create the pcap_t
  ret = pcap_open_live(interface, SNAP_LEN, PROMISC, TIMEOUT, errbuf);
  if (ret == NULL)
  {
    sdh_log(SDH_LOG_ERROR, "Error opening interface for listening");
    return NULL;
  }

  // Compile the filter for this interface
  // enabled Optimize for Filter compile to avoid memory exception on big port lists
  if ( pcap_compile(ret, &fp, filter, 1, 0 ) == -1 ) {
      sdh_log(SDH_LOG_ERROR, "Error compiling filter");
      return NULL;
  }
  // Apply the filter
  if (pcap_setfilter(ret, &fp) != 0 ) {
    sdh_log(SDH_LOG_ERROR, "Error setting filter");
    return NULL;
  }
  // Only listen to input traffic
  if (pcap_setdirection(ret, PCAP_D_IN) == -1) {
    sdh_log(SDH_LOG_ERROR, "Error setting direction");
    return NULL;
  }
  return ret;
}

/**
 * If -a has been specified, we just want to set all interfaces, instead of
 * specifying form a file. This uses PCAP to enumerate all usable interfaces,
 * and skips over a few common ones that we don't want. 
 * */
int use_all_pcap_ints()
{
    pcap_if_t * firstdev;
    pcap_if_t * currentdev;
    char errbuf[PCAP_ERRBUF_SIZE] = "";
    
    
    // If someone specified an interface list AND -a, we'll just overwrite the iface list
    // Should probably throw an error, but whatever. free() anything created for the list
    for (int i = 0; i < num_ifaces; i++)
      free(iface_list[i]);
    // Then reset the count to 0.
    num_ifaces = 0;
    
    // Enumerate a list of all usable interfaces on the system
    if ( pcap_findalldevs( &firstdev, errbuf) == -1)
    {
      sdh_log(SDH_LOG_ERROR, "There was an error opening all devices. Maybe you aren't root.");
      sdh_log(SDH_LOG_ERROR, "%s", errbuf);
      return (-1);
    }
  
    for (currentdev = firstdev; currentdev; currentdev = currentdev->next)
    {
      // We don't want to listen on any USB interfaces, nor on the any 
      // interface. Listeningon the any interface is a bad idea, mmkay?
      // Add the iface to the iface_list if it's not those things. 
      if ( strstr(currentdev->name, "any") == NULL 
          && strstr(currentdev->name, "usb") == NULL)
      {
        sdh_log(SDH_LOG_INFO, "Detected and using interface: %s", currentdev->name);
        iface_list[num_ifaces] = malloc(strlen(currentdev->name) + 1);
        strcpy(iface_list[num_ifaces], currentdev->name);
        num_ifaces++;
      }
      
    }
    
    // free()s all of the stuff pcap_findalldevs created
    pcap_freealldevs(firstdev);
    return 0;
}

/** 
 * Read a file containing the list of settings. Reads from in, and puts each
 * line of non-comment non-whitespace input in to a string at dest[offest], 
 * where offset is incremented for each line. Whitespace around a setting is
 * trimmed. 
 *
 * Each line of the file should:
 * - Have any comments preceeded by a # on each line
 * - Be less than 256 characters long
 *
 * @param in pointer to the file to read
 * @return 0 on success, something else on failure. 
 * */
int parse_file(FILE * in, char * dest[], int * offset)
{
  char line[256];
  char * ptr;
  char * linestart;
//  char * lineend;
  char * comment;

  while (fgets( line, 256, in) != NULL)
  {
    // Stop the string at the comment if there is one
    if ( (comment = strchr(line, COMMENT_CHAR)) != NULL)
      *comment='\0';
    ptr=line;
    // Eat up white space at the start of the line
    while ( *ptr != '\0' && isspace(*ptr) )
      ptr++;
    linestart = ptr;
    // Eat up white space after the content
    while (*ptr != '\0' && isspace(*ptr) == 0)
      ptr++;
    *ptr = '\0';
    // Only put it on the dest array if there's something there!
    if (strlen(linestart) > 0)
    {
      dest[*offset] = malloc(strlen(linestart)+1);
      strcpy(dest[*offset], linestart);
      (*offset)++;
    }


  }

  return 0;

}


/** 
 * Takes the list of ports and turns it in to a PCAP compatible filter string
 * to select only configured port numbers.
 *
 * @param portlist An array containing strings containing port number(s). Each
 *                 item should either be a %d or a %d-%d, the latter indicating
 *                 a port range
 * @param numports The number of ports in the array
 * @return The string containing the PCAP filter
 * */
char * generate_filter_string(char * portlist[], int numports)
{
  // Each port entry needs at most "portrange XXXXX-XXXXX or " = ~30 chars
  // Plus the prefix (~42 chars) and closing bracket
  size_t bufsize = 50 + (size_t)numports * 30;
  char *  ret = malloc(bufsize);
  char tmpstr[50] = "";
  char * end; // points to the end of the filter string

  // Filter needs to be only broadcast packets, and UDP
  strcpy(ret, "ether dst ff:ff:ff:ff:ff:ff and udp and (");

  // If we don't have at least one port, the string wont generate properly, 
  // and there will be no port restriction on the retransmitting, so we'll 
  // flood the network with DHCP and other lovely things. 
  if (numports < 1)
  {
    sdh_log(SDH_LOG_ERROR, "No ports specified. Exiting to avoid a network flood.");
    exit(-1);
  }
  end = ret + strlen(ret);

  for (int i = 0; i < numports; i++)
  {
    if (strchr(portlist[i], '-') != NULL)
    {
      // This is a port range
      sprintf(tmpstr, "portrange %s or ", portlist[i] );
    }
    else
    {
      // This is a single port
      sprintf(tmpstr, "port %s or ", portlist[i] );
    }

    // Append new port, and move end marker
    strcpy(end, tmpstr);
    end += strlen(tmpstr);
  }

  // Cut off the last "and ", and put a closing bracket on it, then EOF
  *(end-4) = ')';
  *(end-3) = '\0';
  return ret;
}

void printhelp()
{

    printf("\n\nService Discovery Helper\n(c) Chris 'SirSquidness' Holman, 2013\n \
Licensed under the MIT License\n\n \
Usage:\n \
  sudo ./sdh-proxy [-p ports-file -i interfaces-file [-d ]] [-h]\n \
  \n \
  Program must be run with PCAP capture+inject privileges (typically root)\n\
  \n \
  -p ports-file: List of ports are read from ports-file. Port ranges\n \
                 can be specified by using a hyphen, eg 10-50 \n \
  -i interfaces-file: List of interfaces are read from interfaces-file.\n \
  -c config-file: Load configuration from config-file.\n \
                   Auto-loads /etc/sdh-proxy.conf if no flags given.\n \
  -a : Use all interfaces (ignores any interface files given) \n\
  -r : Enable rate limiting per source IP+destination UDP port combination\n \
  -t nnn : Set rate limiter to nnn ms. Defaults to 1000ms. Implies -r\n \
  -d : Turns on debug (doesn't do much yet)\n \
  -l : Turns on Stat logging (log RX/TX Packets to stat.log)\n \
  -h : Shows this help\n \
  \n\
  Multiple port and interface files can be specified.\n\
  \n\n");
}

void signal_handler(int sig)
{
    (void)sig;
    do_exit = 1;
}

/**
 * Sorry for the long main(). It just happened, okay?
 */
int main(int argc, char * argv[])
{
  // Stores a list of threads 
  pthread_t * threads;
  
  int i;

  if ( getuid() != 0 && geteuid() != 0)
  {
    sdh_log(SDH_LOG_ERROR, "Not running program as root. Crashes and segfaults may result.");
    fflush(stdout);
  }

  signal(SIGTERM, signal_handler);
  signal(SIGINT, signal_handler);
  sdh_log_debug_enabled = debug;
  sdh_log_init(0);

  /******
   * Begin processing command line arguments 
   * *****/
  
  // Read in arguments
  for (i = 1; i < argc; i++)
  {
    // -p, port list file
    if ( strcmp("-p", argv[i]) == 0)
    {
      if (++i < argc)
      {
        char * filename = argv[i];
        FILE * portfile;
        portfile = fopen(filename, "rt");
        if ( portfile == NULL || parse_file(portfile, port_list, &num_ports) != 0)
        {
          sdh_log(SDH_LOG_ERROR, "Error opening or parsing the ports list file, %s", filename);
          return -1;
        }
        fclose(portfile);
      }
      else
      {
        sdh_log(SDH_LOG_ERROR, "-p specified, but no filename");
        return -1;
      }

    }
    // -i, interface list file
    else if (strcmp("-i", argv[i]) == 0)
    {

      if (++i < argc)
      {
        char * filename = argv[i];
        FILE * ifacefile;
        ifacefile = fopen(filename, "rt");
        if ( ifacefile == NULL || parse_file(ifacefile, iface_list, &num_ifaces) != 0)
        {
          sdh_log(SDH_LOG_ERROR, "Error opening or parsing the interface list file, %s", filename);
          return -1;
        }
        fclose(ifacefile);
      }
      else
      {
        sdh_log(SDH_LOG_ERROR, "-i specified, but no filename");
        return -1;
      }
    }
    // -r Enable rate limiter
    else if (strcmp("-r", argv[i]) == 0)
    {
      timer_enabled =1;
    }
    else if (strcmp("-t", argv[i]) == 0)
    {
      // -t takes a value for the rate limiter tiem limit
      if (++i < argc)
      {
        unsigned int ms;
        if (sscanf(argv[i], "%u", &ms) == 0 || ms == 0)
        {
          sdh_log(SDH_LOG_ERROR, "Specified -t but gave an unreadable input for it. Exiting.");
          return (-1);
        }
        if (ms < 100)
          sdh_log(SDH_LOG_INFO, "Rate limiter time limit set very low (%ums). This is NOT advisable.", ms);
        pkt_timeout_s = ms / 1000;
        pkt_timeout_us = (ms - pkt_timeout_s*1000)*1000;
        timer_enabled =1;
        sdh_log(SDH_LOG_DEBUG, "Set rate limiter to %us, %uus", pkt_timeout_s, pkt_timeout_us);
      }
      else
      {
        sdh_log(SDH_LOG_ERROR, "Specified -t but gave no extra argument. Exiting.");
        return (-1);
      }
    }
    // -d, debug
    else if (strcmp("-d", argv[i]) == 0)
    {
      debug = 1;
    }
    // -l, log stats
    else if (strcmp("-l", argv[i]) == 0)
    {
      logstat = 1;
    }
    // -a, all interfaces
    else if (strcmp("-a", argv[i]) == 0)
      use_all_interfaces = 1;
    // -c, config file
    else if (strcmp("-c", argv[i]) == 0)
    {
      if (++i < argc)
        config_file = argv[i];
      else
      {
        sdh_log(SDH_LOG_ERROR, "-c specified, but no filename");
        return -1;
      }
    }
    // -h, help
    else if (strcmp("-h", argv[i]) == 0)
      printhelp();
    else
    {
      sdh_log(SDH_LOG_ERROR, "Unknown argument given. Exiting to avoid unexpected actions");
      printhelp();
      return -1;
    }

  }

  /****
   * End processing command line options
   * *****/

  // Auto-discover config if no -c given and nothing else configured
  if (!config_file && num_ports == 0 && num_ifaces == 0 && !use_all_interfaces)
  {
      FILE *test = fopen("/etc/sdh-proxy.conf", "r");
      if (test)
      {
          fclose(test);
          config_file = "/etc/sdh-proxy.conf";
          sdh_log(SDH_LOG_INFO, "Auto-detected config: /etc/sdh-proxy.conf");
      }
  }

  if (config_file)
  {
      if (sdh_config_load(config_file) != 0)
          return -1;
  }

  // Show help if still nothing configured
  if (num_ports == 0 && num_ifaces == 0 && !use_all_interfaces)
  {
      printhelp();
      return -1;
  }

  // If we're using all interfaces, get PCAP to tell us what ifaces are available
  if (use_all_interfaces)
    if (use_all_pcap_ints() == -1)
      return(-1);
  

  {
    sdh_log(SDH_LOG_DEBUG, "Ports being retransmitted:");
    for (int i = 0; i < num_ports; i++)
      sdh_log(SDH_LOG_DEBUG, "\t%s", port_list[i]);
    sdh_log(SDH_LOG_DEBUG, "Interfaces being listend and transmitted on:");
    for (int i = 0; i < num_ifaces; i++)
      sdh_log(SDH_LOG_DEBUG, "\t%s", iface_list[i]);
  }

  if (num_ports == 0 || num_ifaces == 0)
  {
    sdh_log(SDH_LOG_ERROR, "Either no ports or no interfaces specified. Nothing to do.");
    return (-1);
  }

  // PCAP filter 
  filter = generate_filter_string(port_list, num_ports);
  sdh_log(SDH_LOG_DEBUG, "Using filter:%s", filter);


  iface_data = malloc( num_ifaces * sizeof(interface_data) );
  threads = malloc ((num_ifaces + 1) * sizeof(pthread_t));
  

  // Create all of the interface listeners
  for (i = 0; i < num_ifaces; i++)
  {
    iface_data[i].interface =   iface_list[i];
    iface_data[i].pcap_int = init_pcap_int(iface_list[i], iface_data[i].pcap_errbuf );
    if (iface_data[i].pcap_int == NULL)
    {
      sdh_log(SDH_LOG_ERROR, "Couldn't create a listener for all interfaces. Exiting. (%d)",i);
      return -1;
    }
  }

  // Inits the thread lock in the timer 
  timer_init();

  // Once all pcap_ts are created, then spawn the processing threads
  for (i = 0; i< num_ifaces; i++)
  {
    pthread_create(&threads[i], NULL, start_listening, &iface_data[i]);
  }
 
  // Init the hash table purging thread
  // Don't care about joining it; when the program dies, it can die too. 
  if(timer_enabled)
    pthread_create(&threads[i++], NULL,timer_purge_old_entries_loop, NULL); 

  // Wait until do_exit is set (by signal handler)
  while (!do_exit)
      sleep(1);

  // Break all pcap loops so threads can exit
  for (i = 0; i < num_ifaces; i++)
      pcap_breakloop(iface_data[i].pcap_int);

  // Join all worker threads
  for (i = 0; i < num_ifaces; i++)
      pthread_join(threads[i], NULL);

  // Join purge thread if it was started
  if (timer_enabled)
      pthread_join(threads[num_ifaces], NULL);

  // Final stat flush
  if (logstat)
  {
      logtimer = 0;
      writeLogStats();
  }

  // Cleanup
  for (i = 0; i < num_ifaces; i++)
      pcap_close(iface_data[i].pcap_int);
  free(iface_data);
  free(threads);
  free(filter);

  sdh_log_cleanup();
  return 0;
}
