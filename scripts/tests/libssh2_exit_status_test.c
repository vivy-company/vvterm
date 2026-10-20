/* Run against the pinned upstream source and macOS library after scripts/build.sh ssh. */
#include "libssh2_priv.h"
#include "packet.h"
#include "misc.h"
#include <assert.h>
#include <stdio.h>

static void receive_status(LIBSSH2_SESSION *session, uint32_t status,
                           size_t length)
{
    unsigned char *packet = SSH2_ALLOC(session, 25);
    assert(packet);
    memset(packet, 0, 25);
    packet[0] = SSH_MSG_CHANNEL_REQUEST;
    ssh2_htonu32(packet + 1, 7);
    ssh2_htonu32(packet + 5, 11);
    memcpy(packet + 9, "exit-status", 11);
    packet[20] = 0; /* No reply requested. */
    ssh2_htonu32(packet + 21, status);
    int result = ssh2_packet_add(session, packet, length, 0, 0);
    assert(result == (length < 25 ? LIBSSH2_ERROR_PROTO : 0));
}

int main(void)
{
    assert(libssh2_init(0) == 0);
    LIBSSH2_SESSION *session = libssh2_session_init();
    assert(session);
    LIBSSH2_CHANNEL channel;
    memset(&channel, 0, sizeof(channel));
    channel.session = session;
    channel.local.id = 7;
    ssh2_list_add(&session->channels, &channel.node);
    assert(!libssh2_channel_has_exit_status(NULL));
    assert(!libssh2_channel_has_exit_status(&channel));
    receive_status(session, 0, 24); /* Incomplete status must not count. */
    assert(!libssh2_channel_has_exit_status(&channel));
    receive_status(session, 0, 25);
    assert(libssh2_channel_has_exit_status(&channel));
    assert(libssh2_channel_get_exit_status(&channel) == 0);
    receive_status(session, 23, 25);
    assert(libssh2_channel_has_exit_status(&channel));
    assert(libssh2_channel_get_exit_status(&channel) == 23);
    receive_status(session, UINT32_MAX, 25);
    assert((uint32_t)libssh2_channel_get_exit_status(&channel) == UINT32_MAX);
    ssh2_list_remove(&channel.node);
    assert(libssh2_session_free(session) == 0);
    libssh2_exit();
    puts("PASS: absent, malformed, zero, nonzero, and full-width exit status");
    return 0;
}
