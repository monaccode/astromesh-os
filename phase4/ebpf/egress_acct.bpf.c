// Fase 4.4/4.4e: cgroup_skb/egress — per-flow egress byte/packet accounting + enforcement. Counts every
// flow (4.4) and DROPS (return 0) flows present in the `deny` map, which the Rust daemon populates when a
// flow exceeds its byte quota (4.4e). The Fase 3.5 IPAddressDeny filter still governs. Classic (no CO-RE).
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>

struct flow_key {
    __u32 daddr;   // network byte order
    __u16 dport;   // network byte order
    __u8  proto;
    __u8  pad;
};

struct flow_stat {
    __u64 bytes;
    __u64 packets;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, struct flow_key);
    __type(value, struct flow_stat);
} flows SEC(".maps");

// Fase 4.4e: deny map — flows the userspace daemon decided to block (over quota). Presence => drop.
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, struct flow_key);
    __type(value, __u8);
} deny SEC(".maps");

// cgroup_skb: skb->data points at the IP header (L3), not Ethernet.
SEC("cgroup_skb/egress")
int egress_acct(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    struct iphdr *iph = data;
    if ((void *)(iph + 1) > data_end)
        return 1;
    if (iph->version != 4)
        return 1;

    struct flow_key key = {};
    key.daddr = iph->daddr;
    key.proto = iph->protocol;

    __u32 ihl = iph->ihl * 4;
    void *l4 = (void *)iph + ihl;
    if (iph->protocol == IPPROTO_TCP) {
        struct tcphdr *th = l4;
        if ((void *)(th + 1) > data_end)
            return 1;
        key.dport = th->dest;
    } else if (iph->protocol == IPPROTO_UDP) {
        struct udphdr *uh = l4;
        if ((void *)(uh + 1) > data_end)
            return 1;
        key.dport = uh->dest;
    }

    // Fase 4.4e: enforcement — drop egress to denied flows (before counting; denied bytes stop accruing).
    if (bpf_map_lookup_elem(&deny, &key))
        return 0;

    struct flow_stat *st = bpf_map_lookup_elem(&flows, &key);
    if (st) {
        __sync_fetch_and_add(&st->bytes, skb->len);
        __sync_fetch_and_add(&st->packets, 1);
    } else {
        struct flow_stat init = { .bytes = skb->len, .packets = 1 };
        bpf_map_update_elem(&flows, &key, &init, BPF_NOEXIST);
    }
    return 1;   // allow — accounting only
}

char LICENSE[] SEC("license") = "GPL";
