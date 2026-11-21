// Declarations for Darwin interfaces that exist on every Mac but are absent
// from the public SDK headers.
//
// These are written by hand to match the layouts in Apple's published XNU and
// libpcap sources. They are deliberately given `sb_` names so they can never
// collide with a future SDK that does export them. Every consumer checks the
// kernel-reported record length against `sizeof` at runtime and refuses to
// parse on a mismatch, so a layout change fails loudly instead of misreading.

#ifndef CDARWIN_PRIVATE_H
#define CDARWIN_PRIVATE_H

#include <stdint.h>
#include <sys/types.h>
#include <pcap/pcap.h>

// MARK: - Kernel socket list (sysctl net.inet.{tcp,udp}.pcblist_n)
//
// The sysctl returns a header, then a run of self-describing records. Each
// record starts with a length and a kind; one socket is described by one
// record of each kind. Records are padded to 8-byte boundaries.

#pragma pack(push, 4)

struct sb_xinpgen {
    uint32_t xig_len;
    uint32_t xig_count;
    uint64_t xig_gen;
    uint64_t xig_sogen;
};

// Common prefix of every record.
struct sb_xgen_n {
    uint32_t xgn_len;
    uint32_t xgn_kind;
};

struct sb_xsocket_n {
    uint32_t xso_len;
    uint32_t xso_kind;
    uint64_t xso_so;
    int16_t  so_type;
    uint32_t so_options;
    int16_t  so_linger;
    int16_t  so_state;
    uint64_t so_pcb;
    int32_t  xso_protocol;
    int32_t  xso_family;
    int16_t  so_qlen;
    int16_t  so_incqlen;
    int16_t  so_qlimit;
    int16_t  so_timeo;
    uint16_t so_error;
    pid_t    so_pgid;
    uint32_t so_oobmark;
    uid_t    so_uid;
    pid_t    so_last_pid;
    pid_t    so_e_pid;
    uint64_t so_gencnt;
    uint32_t so_flags;
    uint32_t so_flags1;
    int32_t  so_usecount;
    int32_t  so_retaincnt;
    uint32_t xso_filter_flags;
};

struct sb_xsockbuf_n {
    uint32_t xsb_len;
    uint32_t xsb_kind;
    uint32_t sb_cc;
    uint32_t sb_hiwat;
    uint32_t sb_mbcnt;
    uint32_t sb_mbmax;
    int32_t  sb_lowat;
    int16_t  sb_flags;
    int16_t  sb_timeo;
};

struct sb_data_stats {
    uint64_t rxpackets;
    uint64_t rxbytes;
    uint64_t txpackets;
    uint64_t txbytes;
};

#define SB_SO_TC_STATS_MAX 4

struct sb_xsockstat_n {
    uint32_t xst_len;
    uint32_t xst_kind;
    struct sb_data_stats xst_tc_stats[SB_SO_TC_STATS_MAX];
};

struct sb_xinpcb_n {
    uint32_t xi_len;
    uint32_t xi_kind;
    uint64_t xi_inpp;
    uint16_t inp_fport;      // network byte order
    uint16_t inp_lport;      // network byte order
    uint64_t inp_ppcb;
    uint64_t inp_gencnt;
    int32_t  inp_flags;
    uint32_t inp_flow;
    uint8_t  inp_vflag;
    uint8_t  inp_ip_ttl;
    uint8_t  inp_ip_p;
    // 16 bytes each. An IPv4 address occupies the last four.
    // Declared as words so the fields keep the 4-byte alignment of the
    // unions they stand in for.
    uint32_t inp_faddr[4];
    uint32_t inp_laddr[4];
    uint8_t  inp4_ip_tos;
    struct {
        uint8_t  inp6_hlim;
        int32_t  inp6_cksum;
        uint16_t inp6_ifindex;
        int16_t  inp6_hops;
    } inp_depend6;
    uint32_t inp_flowhash;
    uint32_t inp_flags2;
};

#define SB_TCPT_NTIMERS_EXT 4

// Only the leading fields of the TCP control block record. The kernel record
// is much longer; we read the state and nothing after it.
struct sb_xtcpcb_n_prefix {
    uint32_t xt_len;
    uint32_t xt_kind;
    uint64_t t_segq;
    int32_t  t_dupacks;
    int32_t  t_timer[SB_TCPT_NTIMERS_EXT];
    int32_t  t_state;
    uint32_t t_flags;
};

#pragma pack(pop)

// MARK: - PKTAP (packet capture with process metadata)

// Exported by libpcap but not declared in <pcap/pcap.h>.
int pcap_set_want_pktap(pcap_t *, int);

#define SB_PKTAP_IFXNAMESIZE 24   // IF_NAMESIZE + 8
#define SB_PKTAP_COMM_SIZE   17   // MAXCOMLEN + 1

// Header the kernel prepends to each packet on a pktap interface.
struct sb_pktap_header {
    uint32_t pth_length;              // length of this header
    uint32_t pth_type_next;
    uint32_t pth_dlt;                 // link type of the frame that follows
    char     pth_ifname[SB_PKTAP_IFXNAMESIZE];
    uint32_t pth_flags;
    uint32_t pth_protocol_family;
    uint32_t pth_frame_pre_length;
    uint32_t pth_frame_post_length;
    pid_t    pth_pid;
    char     pth_comm[SB_PKTAP_COMM_SIZE];
    uint8_t  pth_ipproto;
    uint16_t pth_trace_tag;
    uint32_t pth_svc;
    uint16_t pth_iftype;
    uint16_t pth_ifunit;
    pid_t    pth_epid;                // effective pid (the process acted for)
    char     pth_ecomm[SB_PKTAP_COMM_SIZE];
    uint8_t  pth_pad2;
    uint16_t pth_pad3;
    uint32_t pth_flowid;
    uint32_t pth_comp_gencnt;
    struct {
        int32_t tv_sec;
        int32_t tv_usec;
    } pth_tstamp;
    uint8_t  pth_uuid[16];
    uint8_t  pth_euuid[16];
};

#endif
