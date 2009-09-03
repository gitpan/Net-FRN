package Net::FRN::Client;

require 5.001;

use strict;
use utf8;

use IO::Socket::INET;
use IO::Select;
use POSIX;
use Carp;
use Net::FRN::Const;

my $HAS_AUDIO_GSM;
my $HAS_WIN32_SOUND;
my $HAS_WIN32_ACM;

BEGIN {
    $HAS_AUDIO_GSM   = eval("use Audio::GSM")   && !$!;
    $HAS_WIN32_SOUND = eval("use Win32::Sound") && !$!;
    $HAS_WIN32_ACM   = eval("use Win32::ACM")   && !$!;
}

do { # Constants
    use constant STATE_NONE            => 0x00;
    use constant STATE_PROTO_HANDSHAKE => 0x01;
    use constant STATE_LOGIN_RESULT    => 0x02;
    use constant STATE_MESSAGE_HEADER  => 0x03;
    use constant STATE_MESSAGE         => 0x04;
    use constant STATE_RX_FRAME        => 0x06;
    use constant STATE_CLIENTS_HEADER  => 0x07;
    use constant STATE_CLIENTS         => 0x08;
    use constant STATE_NETWORKS_HEADER => 0x09;
    use constant STATE_NETWORKS        => 0x0A;
    use constant STATE_SND_FRAME_IN    => 0x0B;
    use constant STATE_KEEPALIVE       => 0x0C;
    use constant STATE_DISCONNECTED    => 0x0D;
    use constant STATE_TX_REQUEST      => 0x0E;
    use constant STATE_TX_APROVED      => 0x0F;
    use constant STATE_TX_REJECTED     => 0x10;
    use constant STATE_TX_COMPLETE     => 0x11;
    use constant STATE_PING            => 0x12;
    use constant STATE_ABORT           => 0xFE;
    use constant STATE_IDLE            => 0xFF;
    
    use constant MARKER_KEEPALIVE     => 0x00;
    use constant MARKER_SOUND         => 0x02;
    use constant MARKER_CLIENTS       => 0x03;
    use constant MARKER_MESSAGE       => 0x04;
    use constant MARKER_NETWORKS      => 0x05;
    
    use constant KEEPALIVE_TIMEOUT => 1;
};

sub new {
    my $class = shift;
    $class = ref $class if ref $class;
    my ($peer, %arg);
    if (@_ % 2) {
      $peer = shift;
      %arg  = @_;
    } else {
      %arg  = @_;
      $peer = delete $arg{Host};
    }
    my $gsm;
    if ($HAS_AUDIO_GSM) {
        no strict 'subs';
        $gsm = new Audio::GSM;
        $gsm->option(GSM_OPT_WAV49, 1);
    } elsif ($HAS_WIN32_ACM) {
        $gsm = new Win32::ACM;
    }
    my $self = {
        _socket        => undef,
        _select        => new IO::Select,
        _gsm           => $gsm,
        _VX            => FRN_PROTO_VERSION,
        _ON            => $arg{Name},
        _EA            => $arg{Email},
        _PW            => $arg{Password},
        _NT            => $arg{Net} || 'Test',
        _NN            => $arg{Country} || '',
        _CT            => $arg{City} || 'N/A - N/A',
        _BC            => $arg{Type} || FRN_TYPE_PC_ONLY,
        _BN            => undef,
        _BP            => undef,
        _SV            => undef,
        _clients       => [],
        _networks      => [],
        _inbuffer      => '',
        _outbuffer     => '',
        _bytesExpected => 0,
        _linesExpected => 0,
        _state         => STATE_NONE,
        _lastKA        => 0,
        _callback      => {
            onConnect          => undef,
            onDisconnect       => undef,
            onPing             => undef,
            onKeepAlive        => undef,
            onLogin            => undef,
            onIdle             => undef,
            onClientList       => undef,
            onNetworkList      => undef,
            onMessage          => undef,
            onPrivateMessage   => undef,
            onBroadcastMessage => undef,
            onRX               => undef,
            onGSM              => undef,
            onPCM              => undef,
            onTXRequest        => undef,
            onTXAprove         => undef,
            onTXReject         => undef,
            onTXComplete       => undef,
        },
        _localAddr     => $arg{LocalAddr},
        _Host          => $peer,
        _Port          => $arg{Port}
    };
    bless($self, $class);
    return $self;
}

# public methods

sub handler {
    my $self     = shift;
    my $callback = shift;
    my $coderef  = shift;
    return undef unless exists($self->{_callback}{$callback});
    my $oldCoderef = $self->{_callback}{$callback};
    if ($coderef) {
        $self->{_callback}{$callback} = $coderef;
    }
    return $oldCoderef;
}

sub run {
    my $self = shift;
    $self->{_state} = STATE_DISCONNECTED;
    while ($self->{_state} != STATE_ABORT) {
        $self->_read;
        $self->_parse;
        $self->_write;
    }
}

sub read {
    my $self = shift;
    $self->_read;
}

sub write {
    my $self = shift;
    $self->_write;
}

sub parse {
    my $self = shift;
    $self->_parse;
}

sub transmitGSM {
    my $self = shift;
    $self->_tx(0);
}

sub status {
    my $self = shift;
    my $status = shift;
    return $self->_status($status);
}

sub message {
    my $self = shift;
    my $text = shift;
    my $ID   = shift;
    my $rv = $self->_message(ID => $ID, MS => $text);
    $rv &= $self->_ping;
    return $rv;
}

# private methods

sub _read {
    my $self = shift;
    my $buff = '';
    my $rv;
    if ($self->{_state} != STATE_DISCONNECTED && $self->{_select}->can_read(1 * !length($self->{_outbuffer}) * !length($self->{_inbuffer}))) {
        if ($self->{_select}->can_read(1)) {
            use bytes;
            $rv = $self->{_socket}->recv($buff, POSIX::BUFSIZ, 0);
            if (!defined $rv) {
                $self->{_select}->remove($self->{_socket});
                $self->{_state} = STATE_DISCONNECTED;
            }
            $self->{_inbuffer} .= $buff;
        }
    }
    return $rv;
}

sub _write {
    my $self = shift;
    my $rv;
    if (
        $self->{_state} != STATE_DISCONNECTED
        && length($self->{_outbuffer})
        #&& $self->{_select}->can_write(0)
    ) {
        $rv = $self->{_socket}->send($self->{_outbuffer}, length($self->{_outbuffer}), 0);
        $self->{_socket}->flush();
        if (!defined $rv) {
            $self->{_select}->remove($self->{_socket});
            $self->{_state} = STATE_DISCONNECTED;
        }
        $self->{_outbuffer} = '';
    } elsif (!length($self->{_outbuffer})) {
        $rv = 0;
    }
    return $rv;
}

sub _parse {
    my $self = shift;
    # parsing
    if ($self->{_state} == STATE_DISCONNECTED) {
        printf("Connecting to %s:%i...\n", $self->{_Host}, $self->{_Port});
        if ($self->_connect) {
            $self->_login;
            $self->{_state} = STATE_PROTO_HANDSHAKE;
        } else {
            # TODO connect to backup server
            die $!;
        }
    } elsif ($self->{_state} == STATE_PROTO_HANDSHAKE && $self->_checkLines(1)) {
        my $line = $self->_getLine;
        if (int($line) > FRN_PROTO_VERSION) {
            warn "Protocol has changed! Client may work improperly!\n";
        }
        $self->{_state} = STATE_LOGIN_RESULT;
    } elsif ($self->{_state} == STATE_LOGIN_RESULT && $self->_checkLines(1)) {
        my $line = $self->_getLine;
        my %result = $self->_parseStruct($line);
        $self->{_SV} = $result{SV};
        $self->{_BN} = $result{BN};
        $self->{_BP} = $result{BP};
        if ($result{AL} eq FRN_RESULT_OK) {
            $self->_rx;
            if ($self->{_callback}{onLogin}) {
                &{$self->{_callback}{onLogin}}();
            }
            $self->{_state} = STATE_IDLE;
        } elsif ($result{AL} eq FRN_RESULT_WRONG) {
            die "Password incorrect";
        } elsif ($result{AL} eq FRN_RESULT_NOK) {
            die "Server has rejected your login";
        }
        $self->{_state} = STATE_IDLE;
    } elsif ($self->{_state} == STATE_MESSAGE_HEADER && $self->_checkLines(1)) {
        $self->{_linesExpected} = $self->_getLine;
        $self->{_state} = STATE_MESSAGE;
    } elsif ($self->{_state} == STATE_MESSAGE && $self->_checkLines($self->{_linesExpected})) {
        my $message = {};
        my $line = $self->_getLine;
        $message->{from} = (grep {$_->{ID} eq $line} @{$self->{_clients}})[0];
        foreach(2..($self->{_linesExpected} - 1)) {
            $message->{text} .= $message->{text} ? "\r\n" : '';
            $message->{text} .= $self->_getLine;
        }
        $message->{type} = $self->_getLine;
        if ($message->{type} eq FRN_MESSAGE_PRIVATE && $self->{_callback}{onPrivateMessage}) {
            &{$self->{_callback}{onPrivateMessage}}($message);
        } elsif ($message->{type} eq FRN_MESSAGE_BROADCAST && $self->{_callback}{onBroadcastMessage}) {
            &{$self->{_callback}{onBroadcastMessage}}($message);
        } elsif ($self->{_callback}{onMessage}) {
            &{$self->{_callback}{onMessage}}($message);
        }
        $self->{_state} = STATE_IDLE;
    } elsif ($self->{_state} == STATE_CLIENTS_HEADER && $self->_checkLines(1)) {
        @{$self->{_clients}} = ();
        $self->_getBytes(2);
        $self->{_linesExpected} = $self->_getLine;
        $self->{_state} = STATE_CLIENTS;
    } elsif ($self->{_state} == STATE_CLIENTS && $self->_checkLines($self->{_linesExpected})) {
        foreach (1..$self->{_linesExpected}) {
            my $line = $self->_getLine;
            my %client = $self->_parseStruct($line);
            push(@{$self->{_clients}}, \%client);
        }
        if ($self->{_callback}{onClientList}) {
            &{$self->{_callback}{onClientList}}($self->{_clients});
        }
        $self->{_state} = STATE_IDLE;
    } elsif ($self->{_state} == STATE_NETWORKS_HEADER && $self->_checkLines(1)) {
        @{$self->{_networks}} = ();
        my $line = $self->_getLine;
        $self->{_linesExpected} = $line;
        $self->{_state} = STATE_NETWORKS;
    } elsif ($self->{_state} == STATE_NETWORKS && $self->_checkLines($self->{_linesExpected})) {
        foreach (1..$self->{_linesExpected}) {
            push(@{$self->{_networks}}, $self->_getLine);
        }
        if ($self->{_callback}{onNetworkList}) {
            &{$self->{_callback}{onNetworkList}}($self->{_networks});
        }
        $self->{_state} = STATE_IDLE;
    } elsif ($self->{_state} == STATE_SND_FRAME_IN && $self->_checkBytes(327)) {
        my $bc = $self->_getBytes(2);
        my $clientIdx = unpack('%n', $bc);
        if ($self->{_callback}{onRX}) {
            &{$self->{_callback}{onRX}}($self->{_clients}[$clientIdx - 1]);
        }
        my $frame10 = $self->_getBytes(325);
        if ($self->{_callback}{onGSM}) {
            my $pcmBuffer = &{$self->{_callback}{onGSM}}($frame10);
        } elsif ($self->{_gsm}) { # perform decoding only if GSM codec installed
            my $pcmBuffer = '';
            for (my $i = 0; $i < 5; $i++) {
                my @frames = (substr($frame10, 0, 33, ''), substr($frame10, 0, 32, ''));
                $pcmBuffer .= $self->{_gsm}->decode($frames[0]);
                $pcmBuffer .= $self->{_gsm}->decode($frames[1]);
            }
            if ($self->{_callback}{onPCM}) {
                &{$self->{_callback}{onPCM}}($pcmBuffer);
            }
        }
        $self->{_state} = STATE_IDLE;
    } elsif ($self->{_state} == STATE_KEEPALIVE) {
        if ($self->{_callback}{onKeepAlive}) {
            &{$self->{_callback}{onKeepAlive}}();
        }
        $self->{_state} = STATE_PING;
    } elsif ($self->{_state} == STATE_PING) {
        $self->_ping;
        if ($self->{_callback}{onPing}) {
            &{$self->{_callback}{onPing}}();
        }
        $self->{_state} = STATE_IDLE;
    } elsif ($self->{_state} == STATE_TX_REQUEST && $self->_checkBytes(1)) {
        my $aprove = $self->_getBytes(1);
        if ($aprove) {
            $self->{_state} = STATE_TX_APROVED;
        } else {
            $self->{_state} = STATE_TX_REJECTED;
        }
    } elsif ($self->{_state} == STATE_TX_APROVED) {
        if ($self->{_callback}{onTXAprove}) {
            &{$self->{_callback}{onTXAprove}}();
        }
        $self->{_state} = STATE_IDLE;
    } elsif ($self->{_state} == STATE_TX_REJECTED) {
        if ($self->{_callback}{onTXReject}) {
            &{$self->{_callback}{onTXReject}}();
        }
        $self->{_state} = STATE_IDLE;
    } elsif ($self->{_state} == STATE_TX_COMPLETE) {
        $self->_rx;
        if ($self->{_callback}{onTXComplete}) {
            &{$self->{_callback}{onTXComplete}}();
        }
        $self->{_state} = STATE_IDLE;
    } elsif ($self->{_state} == STATE_IDLE) {
        if (time() - $self->{_lastKA} > KEEPALIVE_TIMEOUT) {
            $self->{_state} = STATE_PING;
        } elsif ($self->_checkBytes(1)) {
            my $char = $self->_getBytes(1);
            my $marker = ord($char);
            if ($marker == MARKER_KEEPALIVE) {
                $self->{_state} = STATE_KEEPALIVE
            } elsif ($marker == MARKER_CLIENTS) {
                $self->{_state} = STATE_CLIENTS_HEADER;
            } elsif ($marker == MARKER_NETWORKS) {
                $self->{_state} = STATE_NETWORKS_HEADER;
            } elsif ($marker == MARKER_MESSAGE) {
                $self->{_state} = STATE_MESSAGE_HEADER;
            } elsif ($marker == MARKER_SOUND) {
                $self->{_state} = STATE_SND_FRAME_IN;
            } elsif ($marker) {
                die(sprintf('Unknown marker %02X', $marker));
            }
        }
        if ($self->{_callback}{onIdle}) {
            &{$self->{_callback}{onIdle}}();
        }
    }
}

sub _connect {
    my $self = shift;
    $self->{_socket} = IO::Socket::INET->new(
        PeerAddr  => $self->{_Host},
        PeerPort  => $self->{_Port},
        LocalAddr => $self->{_LocalAddr},
        Proto     => 'tcp',
        Timeout   => 30,
    ) or return undef;
    $self->{_select}->add($self->{_socket});
    $self->{_socket}->blocking(0);
    $self->{_socket}->autoflush(1);
    binmode($self->{_socket});
    return $self->{_socket};
}

sub _login {
    my $self = shift;
    $self->{_outbuffer} .= $self->_CT;
}

sub _ping {
    my $self = shift;
    $self->{_lastKA} = time();
    $self->{_outbuffer} .= $self->_P;
}

sub _rx {
    my $self = shift;
    my $mode = shift;
    $self->{_outbuffer} .= $mode ? $self->_RX1 : $self->_RX0;
}

sub _tx {
    my $self = shift;
    my $mode = shift;
    $self->{_outbuffer} .= $mode ? $self->_TX1 : $self->_TX0;
}

sub _message {
    my $self = shift;
    my %args = @_;
    $self->{_outbuffer} .= $self->_TM(%args);
}

sub _status {
    my $self = shift;
    my $status = shift;
    $self->{_outbuffer} .= $self->_ST($status);
}

sub _getBytes {
    my $self   = shift;
    my $nBytes = shift;
    use bytes;
    return substr($self->{_inbuffer}, 0, $nBytes, '');
}

sub _getLine {
    my $self = shift;
    $self->{_inbuffer} =~ s/^(.*)\r\n//g;
    return $1;
}

sub _checkBytes {
    my $self   = shift;
    my $nBytes = shift;
    use bytes;
    return(length($self->{_inbuffer}) >= $nBytes);
}

sub _checkLines {
    my $self   = shift;
    my $nLines = shift;
    return(scalar(@{[$self->{_inbuffer} =~ /\r\n/g]}) >= $nLines);
}

sub _parseStruct {
    my $self = shift;
    my $line = shift;
    my %hash;
    while ($line =~ s/<(\w+)>(.*?)(?:<\/\1>)?(?=<\w+>|$)//) {
        $hash{$1} = $2;
    }
    return %hash;
}

# Commands

sub _CT {
    my $self = shift;
    my $CT = sprintf(
        "CT:<VX>%s</VX><EA>%s</EA><PW>%s</PW><ON>%s</ON><BC>%s</BC><NN>%s</NN><CT>%s</CT><NT>%s</NT>\r\n",
        $self->{_VX},
        $self->{_EA},
        $self->{_PW},
        $self->{_ON},
        $self->{_BC},
        $self->{_NN},
        $self->{_CT},
        $self->{_NT}
    );
    return $CT;
}

sub _P {
    my $self = shift;
    return "P\r\n";
}

sub _RX0 {
    my $self = shift;
    return "RX0\r\n";
}

sub _RX1 {
    my $self = shift;
    return "RX1\r\n";
}

sub _TX0 {
    my $self = shift;
    return "TX0\r\n";
}

sub _TX1 {
    my $self = shift;
    return "TX1\r\n"
}

sub _TM {
    my $self = shift;
    my %args = @_;
    do {
        use bytes;
        $args{MS} .= length($args{MS}) % 2 ? '' : chr(0x00);
    };
    my $TM = sprintf("TM:<ID>%s</ID><MS>%s</MS>\r\n", $args{ID} || '', $args{MS} || '');
    return $TM;
}

sub _ST {
    my $self = shift;
    my $status = shift;
    my $ST = sprintf("ST:%i\r\n", $status);
    return $ST;
}

1;
