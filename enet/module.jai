#module_parameters(DEBUG_FRAME_CAPTURE:=false);

HOST_ANY :: V6_ANY_ADDR;

Event_Type :: enum {
    NONE;
    CONNECT;
    DISCONNECT;
    RECEIVE;
    DISCONNECT_TIMEOUT;
}

Packet_Flags :: enum_flags u16 {
    RELIABLE;
    UNSEQUENCED;
    NO_ALLOCATE;
    UNRELIABLE_FRAGMENT;
    SENT;
}

Address :: struct {
    host: in6_addr;
    port: u16;
    sin6_scope_id: u16;
}

Packet :: struct {
    ref_count:    s32;
    flags:        Packet_Flags;
    data:         *u8;
    data_length:  u32;
    user_data:    *Any;
}

Event :: struct {
    type:        Event_Type;
    peer:        *Peer;
    channel_id:  u8;
    data:        u32;
    packet:      *Packet;
}

initialize :: () -> bool {
    #if OS == .WINDOWS {
        version :u16= (1 << 8) | 1;
        wsa_data : WSAData;

        if WSAStartup(version, *wsa_data) {
            log_error("Failed to initialize enet: Failed to startup WSA");
            return false;
        }

        if wsa_data.wVersion & 1 != 1 || wsa_data.wVersion >> 8 != 1 {
            log_error("Failed to initialize enet: Requested WSA version is % but got %", version, wsa_data.wVersion);
            WSACleanup();
            return false;
        }
    }

    start_time = current_time_monotonic();

    // No initialization needed for unix

    return true;
}

deinitialize :: () {
    #if OS == .WINDOWS {
        WSACleanup();
    }

    // No deinitialization needed for unix
}

packet_create :: (data: *$T, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
    return packet_create(cast(*u8)data, size_of(T), flags);
}

packet_create :: (data: []u8, flags: Packet_Flags = .RELIABLE) -> *Packet #expand {
    return packet_create(cast(*u8)data.data, data.count, flags);
}

packet_create :: (data: *u8, data_length: int, flags: Packet_Flags = .RELIABLE) -> *Packet {
    packet: *Packet;

    assert(data_length >= 0 && data_length <= U32_MAX);

    if flags & .NO_ALLOCATE {
        packet = New(Packet);
        packet.data = xx data;
    } else {
        packet = alloc(size_of(Packet) + data_length);
        packet.data = cast(*u8)(packet) + size_of(Packet);

        if data {
            memcpy(packet.data, data, cast(u32)data_length);
        }
    }

    packet.flags = flags;
    packet.data_length = cast(u32)data_length;
    packet.ref_count = 0;

    return packet;
}

packet_destroy :: (packet: *Packet) {
    free(packet);
}

get_host_ip_address :: (host: string) -> Address, bool {
    address, success := lookup_host(host, true);
    return address, success;
}

get_host_name_address :: (host: string) -> Address, bool {
    address, success := lookup_host(host, false);
    return address, success;
}

#load "host.jai";
#load "peer.jai";

#if DEBUG_FRAME_CAPTURE {
    #load "debug_frame_capture.jai";
}

#scope_module
#import "Basic";
#import "Socket";
#load "protocol.jai";
#load "socket.jai";
#load "list.jai";

start_time : Apollo_Time;

V6_ANY_ADDR :: in6_addr.{.{.[ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ]}};
V6_NO_ADDR  :: in6_addr.{.{.[ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff ]}};

#if OS == .WINDOWS {
    MAX_BUFFER_COUNT :s32: cast(s32)MSG.MSG_MAXIOVLEN;
} else {
    MAX_BUFFER_COUNT :: 1 + 2 * PROTOCOL_MAX_PACKET_COMMANDS; 
}

Result_Status :: enum {
    NONE;
    SUCCESS;
    ERROR;
    FAILURE;
}

Channel :: struct {
    used_reliable_windows: type_of(PEER_RELIABLE_WINDOWS); 
    reliable_windows:      [PEER_RELIABLE_WINDOWS] u16;

    outgoing_reliable_seq_number:   u16;
    outgoing_unreliable_seq_number: u16;

    incoming_reliable_seq_number: u16;
    incoming_reliable_commands:   List;

    incoming_unreliable_seq_number: u16;
    incoming_unreliable_commands:   List;
}

channel_reset :: (using channel: *Channel) {
    outgoing_reliable_seq_number   = 0;
    outgoing_unreliable_seq_number = 0;
    incoming_reliable_seq_number   = 0;
    incoming_unreliable_seq_number = 0;
    used_reliable_windows          = 0;
    list_clear(*incoming_reliable_commands);
    list_clear(*incoming_unreliable_commands);
    memset(reliable_windows.data, 0, PEER_RELIABLE_WINDOWS * size_of(u16));
}

// Should match WSABUF
Buffer :: struct {
    length: u32;
    data:   *u8;
}

Acknowledgement :: struct {
    #as using list: List_Node;
    sent_time:      u16; // :Time
    command:        Protocol;
}

Command :: struct {
    #as using list:  List_Node;
    packet:         *Packet;
}

Incoming_Command :: struct {
    #as using base:         Command;
    reliable_seq_number:    u16;
    unreliable_seq_number:  u16;
    command:                Protocol;
    fragment_count:         u32;
    fragments_remaining:    u32;
    fragments:              []u32;
}

Outgoing_Command :: struct {
    #as using base           : Command;
    reliable_seq_number      : u16;
    unreliable_seq_number    : u16;
    sent_time                : s64;
    round_trip_timeout       : s64;
    round_trip_timeout_limit : s64;
    fragment_offset          : u32;
    fragment_length          : u16;
    send_attempts            : u16;
    command                  : Protocol;
}

random_seed :: () -> u64 {
    #if OS == .WINDOWS {
        return cast(u64)Windows.timeGetTime();
    } else {
        return cast(u64)time(null);
    }
}

lookup_host :: (name: string, no_dns: bool) -> Address, bool {
    result_list: *addrinfo;
    result_address: Address;

    hints: addrinfo;
    hints.ai_family = AF_UNSPEC;

    if no_dns hints.ai_flags = .NUMERICHOST;

    hostname := temp_c_string(name);

    defer freeaddrinfo(result_list);
    if getaddrinfo(hostname, null, *hints, *result_list) != 0 {
        return result_address, false;
    }

    result := result_list;
    while result != null {
        defer result += 1;

        if result.ai_addr != null {
            if result.ai_family == AF_INET || (result.ai_family == AF_UNSPEC && result.ai_addrlen == size_of(sockaddr_in)) {
                sock_addr : *sockaddr_in = cast(*sockaddr_in)result.ai_addr;
                result_address.host = map_ip4_to_ip6(sock_addr.sin_addr);
                result_address.sin6_scope_id = 0;
                return result_address, true;
            } else if result.ai_family == AF_INET6 || (result.ai_family == AF_UNSPEC && result.ai_addrlen == size_of(sockaddr_in6)) {
                sock_addr : sockaddr_in6 = cast(*sockaddr_in6)result.ai_addr;
                result_address.host = sock_addr.sin6_addr;
                result_address.sin6_scope_id = xx sock_addr.sin6_scope_id;
                return result_address, true;
            }
        }
    }

    return result_address, false;
}

map_ip4_to_ip6 :: (addr: in_addr) -> in6_addr {

    if addr.S_un.S_addr == 0x00000000 {
        return xx V6_ANY_ADDR;
    } else if addr.S_un.S_addr == 0xFFFFFFFF {
        return xx V6_NO_ADDR; 
    }

    result: in6_addr;
    result.u.Byte[10] = 0xFF;
    result.u.Byte[11] = 0xFF;
    result.u.Byte[12] = (cast(*u8)*addr.S_un.S_addr)[0];
    result.u.Byte[13] = (cast(*u8)*addr.S_un.S_addr)[1];
    result.u.Byte[14] = (cast(*u8)*addr.S_un.S_addr)[2];
    result.u.Byte[15] = (cast(*u8)*addr.S_un.S_addr)[3];

    return result;
}

map_ip4_to_ip6 :: (addr: in6_addr) -> in_addr {
    result: in_addr;
    result.S_addr[0] = (cast(*u8)*addr.S_addr)[0];
    result.S_addr[1] = (cast(*u8)*addr.S_addr)[1];
    result.S_addr[2] = (cast(*u8)*addr.S_addr)[2];
    result.S_addr[3] = (cast(*u8)*addr.S_addr)[3];

    return result;
}

host_to_net_endian_16 :: inline (value: u16 ) -> u16 {
    return htons(value);
}

host_to_net_endian_32 :: inline (value: u32) -> u32 {
    return htonl(value);
}

net_to_host_endian_16 :: inline (value: u16) -> u16 {
    return ntohs(value);
}

net_to_host_endian_32 :: inline (value: u32) -> u32 {
    return ntohl(value);
}

in6_equal :: inline (a: in6_addr, b: in6_addr) -> bool {
    return memcmp(*a, *b, size_of(in6_addr)) == 0;
}

time_difference :: inline (a: s64, b: s64) -> s64 {
    return max(a,b) - min(a,b);
}

#scope_file
#import "Math"; // U32_MAX

#if OS == .WINDOWS {
    Windows :: #import "Windows"; // timeGetTime
}
