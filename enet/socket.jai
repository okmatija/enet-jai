
Socket :: #type SOCKET;

Socket_Options :: enum {
    NONEBLOCK;
    BROADCAST;
    RECEIVE_BUFF;
    SEND_BUFF;
    IPV6_V6ONLY;
}

Socket_Wait :: enum_flags u8 {
    NONE;
    SEND;
    RECEIVE;
    INTERRUPT;
}

socket_create :: () -> Socket {
    return socket(PF_INET6, .DGRAM, 0);
}

socket_destroy :: (socket: Socket) {
    #if OS == .WINDOWS {
        closesocket(socket);
    } else #if OS == .UNIX {
        close(socket);
    }
}

set_socket_options :: (socket: Socket, options: Socket_Options, value: s32) -> bool {
    result: int;

    if options == {
        case .NONEBLOCK;
            #if OS == .WINDOWS {
                result = ioctlsocket(socket, FIONBIO, cast(*u32)*value);
            } else {
                other := fcntl(socket, F_GETFL) & ~O_NONBLOCK;
                result = fcntl(socket, F_SETFL, (ifx value then O_NONBLOCK else 0) | other);
            }
        case .BROADCAST;
            result = setsockopt(socket, SOL_SOCKET, SO_BROADCAST, cast(*u8)*value, size_of(s32));
        case .RECEIVE_BUFF;
            result = setsockopt(socket, SOL_SOCKET, SO_RCVBUF, cast(*u8)*value, size_of(s32));
        case .SEND_BUFF;
            result = setsockopt(socket, SOL_SOCKET, SO_SNDBUF, cast(*u8)*value, size_of(s32));
        case .IPV6_V6ONLY;
            result = setsockopt(socket, xx IPPROTO.IPV6, IPV6_V6ONLY, cast(*u8)*value, size_of(s32));
    }

    if result == -1 return false;

    return true;
}

socket_bind :: (socket: Socket, address: *Address) -> int {
    sin: sockaddr_in6;
    sin.sin6_family = AF_INET6;

    if address {
        sin.sin6_port = host_to_net_endian_16(address.port);
        sin.sin6_addr = address.host;
        sin.sin6_scope_id = address.sin6_scope_id;
    } else {
        sin.sin6_port = 0;
        sin.sin6_addr = HOST_ANY;
        sin.sin6_scope_id = 0;
    }

    return bind(socket, cast(*sockaddr)*sin, size_of(sockaddr_in6));
}

get_socket_address :: (socket: Socket, address: *Address) -> bool {
    sin:     sockaddr_in6;
    sin_len :s32= xx size_of(sockaddr_in6);

    if getsockname(socket, cast(*sockaddr)*sin, *sin_len) == -1 return false;

    address.host = sin.sin6_addr;
    address.port = htons(sin.sin6_port);
    address.sin6_scope_id = xx sin.sin6_scope_id;

    return true;
}

socket_wait :: (socket: Socket, condition: *Socket_Wait, timeout: s64) -> Result_Status {
    #if OS == .WINDOWS {
        read_set:     fd_set;
        write_set:    fd_set;
        time:         timeval;
        select_count: int;

        time.tv_sec  = cast(s32)(timeout / 1000);
        time.tv_usec = cast(s32)(timeout % 1000) * 1000;

        if condition.* & .SEND then FD_SET(socket, *write_set);
        if condition.* & .RECEIVE then FD_SET(socket, *read_set);

        select_count = select(cast(s32)(socket + 1), *read_set, *write_set, null, *time);

        if select_count < 0 then return .ERROR;

        condition.* = .NONE;

        if select_count == 0 then return .NONE;
        if FD_ISSET(socket, *write_set) then condition.* |= .SEND;
        if FD_ISSET(socket, *read_set) then condition.* |= .RECEIVE;

    } else #if OS == .UNIX {
        poll_socket: pollfd;
        poll_count:  int;

        poll_socket.fd     = socket;
        poll_socket.events = 0;

        if condition.* & .WAIT_SEND then poll_socket.events |= POLLOUT;
        if condition.* & .WAIT_RECEIVE then poll_socket.events |= POLLIN;

        poll_count = poll(*poll_socket, 1, timeout);

        if poll_count < 0 {
            if errno() == EINTR && condition.* & .WAIT_INTERRUPT {
                condition.* = .WAIT_INTERRUPT;

                return .NONE;
            }

            return .ERROR;
        }

        condition.* = .WAIT_NONE;

        if poll_count == 0 then return .NONE;
        if poll_socket.revents & POLLOUT then condition.* |= .WAIT_SEND;
        if pollSocket.revents & POLLIN then condition.* |= .WAIT_RECEIVE;
    }

    return .NONE;
}

socket_send :: (socket: Socket, address: *Address, buffers: []Buffer, buffer_count: u32) -> (s32, socket_error: int = 0) {
    sin:         sockaddr_in6;
    sent_length: u32;

    #if OS == .WINDOWS {
        if address != null {
            sin.sin6_family = AF_INET6;
            sin.sin6_port = host_to_net_endian_16(address.port);
            sin.sin6_addr = address.host;
            sin.sin6_scope_id = address.sin6_scope_id;
        }

        buffer_size := 0;
        for 0..buffer_count-1 {
            buffer_size += buffers[it].length;
        }
        if WSASendTo(socket, cast(*WSABUF)buffers.data, xx buffer_count, *sent_length, 0, 
            ifx address then cast(*sockaddr)*sin else null,
            ifx address then cast(s32)size_of(sockaddr_in6) else cast(s32)0,
            null, null) == SOCKET_ERROR {

            error_no := WSAGetLastError();
            return ifx error_no == WSAEWOULDBLOCK then cast(s32)0 else cast(s32)-1, error_no;
        }
    } else #if OS == .UNIX {
        msg_header: msghdr;

        if address != null {
            sin.sin6_family = AF_INET6;
            sin.sin6_port = host_to_net_endian_16(address.port);
            sin.sin6_addr = address.host;
            sin.sin6_scope_id = address.sin6_scope_id;

            msg_header.msg_name = *sin;
            msg_header.msg_namelen = size_of(sockaddr_in6);
        }

        msg_header.msg_iov = cast(*iovec)buffers.data;
        msg_header.msg_iovlen = buffers.count - 1;

        sent_length = send(socket, *msg_header, MSG_NOSIGNAL);

        if sent_length == -1 {
            error_no := errno();
            if error_no == EWOULDBLOCK return cast(s32)0, error_no;

            return cast(s32)-1, error_no;
        }
    }

    return cast(s32)sent_length;
}

socket_receive :: (socket: Socket, address: *Address, buffers: []Buffer, buffer_count: u32) -> (s32, socket_error: int = 0) {
    sin:            sockaddr_in6;
    receive_length: s32;

    #if OS == .WINDOWS {
        flags:      u32;
        sin_length: s32 = size_of(sockaddr_in6);

        result := WSARecvFrom(socket, cast(*WSABUF)buffers.data, buffer_count, cast(*u32)*receive_length, *flags,
            ifx address then cast(*sockaddr)*sin else null,
            ifx address then *sin_length else null,
            null, null);

        if result == SOCKET_ERROR {
            error_no := WSAGetLastError();
            if error_no == {
                case WSAEWOULDBLOCK; 
                    return 0, error_no;
                case WSAECONNRESET; 
                    return 0, error_no;
                case WSAEMSGSIZE;
                    return -2;
            }

            log_error("Socket error from recvfrom %", error_no);
            return -1, error_no;
        }

        if flags & cast(u32)MSG.PARTIAL return -2;

        if address {
            address.host           = sin.sin6_addr;
            address.port           = net_to_host_endian_16(sin.sin6_port);
            address.sin6_scope_id  = xx sin.sin6_scope_id;
        }

    } else #if OS == .UNIX {
        msg_header: msghdr;
        msg_header.msg_name = *sin;
        msg_header.msg_namelen = size_of(sockaddr_in6);

        msg_header.msg_iov = buffers.data;
        msg_header.msg_iovlen = buffer_count;

        receive_length = recvmsg(socket, *msg_header, MSG_NOSIGNAL);

        if receive_length == -1 {
            error_no = errno();
            if err_no == EWOULDBLOCK return cast(u32)0, error_no;

            return -1, error_no;
        }

        if msg_header.msg_flags & MSG_TRUNC return -1;

        if address != null {
            address.host           = sin.sin6_addr;
            address.port           = net_to_host_endian_16(sin.sin6_port);
            address.sin6_scope_id  = xx sin.sin6_scope_id;
        }
    }

    return receive_length;
}
