#!/usr/bin/perl

# (C) Andrey Zelenkov
# (C) Nginx, Inc.

# Tests for mail ssl module.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ :DEFAULT $CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::IMAP;
use Test::Nginx::POP3;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval {
	require Net::SSLeay;
	Net::SSLeay::load_error_strings();
	Net::SSLeay::SSLeay_add_ssl_algorithms();
	Net::SSLeay::randomize();
};
plan(skip_all => 'Net::SSLeay not installed') if $@;

my $t = Test::Nginx->new()->has(qw/mail mail_ssl imap pop3 http rewrite/)
	->has_daemon('openssl')->plan(16);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

mail {
    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;
    ssl_session_tickets off;

    # inherited by server "inherits"
    ssl_password_file password_mail;

    proxy_pass_error_message  on;
    auth_http  http://127.0.0.1:8080/mail/auth;

    ssl_session_cache none;

    server {
        listen             127.0.0.1:8143;
        listen             127.0.0.1:8145 ssl;
        protocol           imap;

        ssl_session_cache  builtin;
        ssl_password_file  password;
    }

    server {
        listen             127.0.0.1:8146 ssl;
        protocol           imap;

        ssl_session_cache  off;
        ssl_password_file  password_many;
    }

    server {
        listen             127.0.0.1:8147;
        protocol           imap;

        # Special case for enabled "ssl" directive.

        ssl on;
        ssl_session_cache  builtin:1000;
        ssl_password_file  password;
    }

    server {
        listen             127.0.0.1:8148 ssl;
        protocol           imap;

        ssl_session_cache shared:SSL:1m;
        ssl_certificate_key inherits.key;
        ssl_certificate inherits.crt;
    }

    server {
        listen             127.0.0.1:8149;
        protocol           imap;

        ssl_password_file  password;
        starttls           on;
    }

    server {
        listen             127.0.0.1:8150;
        protocol           imap;

        ssl_password_file  password;
        starttls           only;
    }

    server {
        listen             127.0.0.1:8151;
        protocol           pop3;

        ssl_password_file  password;
        starttls           on;
    }

    server {
        listen             127.0.0.1:8152;
        protocol           pop3;

        ssl_password_file  password;
        starttls           only;
    }
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location = /mail/auth {
            add_header Auth-Status OK;
            add_header Auth-Server 127.0.0.1;
            add_header Auth-Port %%PORT_8144%%;
            add_header Auth-Wait 1;
            return 204;
        }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 1024
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost', 'inherits') {
	system("openssl genrsa -out '$d/$name.key' -passout pass:$name "
		. "-aes128 1024 >>$d/openssl.out 2>&1") == 0
		or die "Can't create private key: $!\n";
	system('openssl req -x509 -new '
		. "-config '$d/openssl.conf' -subj '/CN=$name/' "
		. "-out '$d/$name.crt' "
		. "-key '$d/$name.key' -passin pass:$name"
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

my $ctx = Net::SSLeay::CTX_new() or die("Failed to create SSL_CTX $!");

$t->write_file('password', 'localhost');
$t->write_file('password_many', "wrong$CRLF" . "localhost$CRLF");
$t->write_file('password_mail', 'inherits');

$t->run_daemon(\&Test::Nginx::IMAP::imap_test_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8144));

###############################################################################

# simple tests to ensure that nothing broke with ssl_password_file directive

my $s = Test::Nginx::IMAP->new();
$s->ok('greeting');

$s->send('1 AUTHENTICATE LOGIN');
$s->check(qr/\+ VXNlcm5hbWU6/, 'login');

# ssl_session_cache

my ($ssl, $ses);

($s, $ssl) = get_ssl_socket(8145);
$ses = Net::SSLeay::get_session($ssl);

($s, $ssl) = get_ssl_socket(8145, $ses);
is(Net::SSLeay::session_reused($ssl), 1, 'builtin session reused');

($s, $ssl) = get_ssl_socket(8146);
$ses = Net::SSLeay::get_session($ssl);

($s, $ssl) = get_ssl_socket(8146, $ses);
is(Net::SSLeay::session_reused($ssl), 0, 'session not reused');

($s, $ssl) = get_ssl_socket(8147);
$ses = Net::SSLeay::get_session($ssl);

($s, $ssl) = get_ssl_socket(8147, $ses);
is(Net::SSLeay::session_reused($ssl), 1, 'builtin size session reused');

($s, $ssl) = get_ssl_socket(8148);
$ses = Net::SSLeay::get_session($ssl);

($s, $ssl) = get_ssl_socket(8148, $ses);
is(Net::SSLeay::session_reused($ssl), 1, 'shared session reused');

# ssl_certificate inheritance

($s, $ssl) = get_ssl_socket(8145);
like(Net::SSLeay::dump_peer_certificate($ssl), qr/CN=localhost/, 'CN');

($s, $ssl) = get_ssl_socket(8148);
like(Net::SSLeay::dump_peer_certificate($ssl), qr/CN=inherits/, 'CN inner');

# starttls imap

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:' . port(8149));
$s->read();

$s->send('1 AUTHENTICATE LOGIN');
$s->check(qr/\+ VXNlcm5hbWU6/, 'imap auth before startls on');

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:' . port(8149));
$s->read();

$s->send('1 STARTTLS');
$s->ok('imap starttls on');

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:' . port(8150));
$s->read();

$s->send('1 AUTHENTICATE LOGIN');
$s->check(qr/^\S+ BAD/, 'imap auth before startls only');

$s = Test::Nginx::IMAP->new(PeerAddr => '127.0.0.1:' . port(8150));
$s->read();

$s->send('1 STARTTLS');
$s->ok('imap starttls only');

# starttls pop3

$s = Test::Nginx::POP3->new(PeerAddr => '127.0.0.1:' . port(8151));
$s->read();

$s->send('AUTH LOGIN');
$s->check(qr/\+ VXNlcm5hbWU6/, 'pop3 auth before startls on');

$s = Test::Nginx::POP3->new(PeerAddr => '127.0.0.1:' . port(8151));
$s->read();

$s->send('STLS');
$s->ok('pop3 starttls on');

$s = Test::Nginx::POP3->new(PeerAddr => '127.0.0.1:' . port(8152));
$s->read();

$s->send('AUTH LOGIN');
$s->check(qr/^-ERR/, 'pop3 auth before startls only');

$s = Test::Nginx::POP3->new(PeerAddr => '127.0.0.1:' . port(8152));
$s->read();

$s->send('STLS');
$s->ok('pop3 starttls only');

###############################################################################

sub get_ssl_socket {
	my ($port, $ses) = @_;
	my $s;

	my $dest_ip = inet_aton('127.0.0.1');
	my $dest_serv_params = sockaddr_in(port($port), $dest_ip);

	socket($s, &AF_INET, &SOCK_STREAM, 0) or die "socket: $!";
	connect($s, $dest_serv_params) or die "connect: $!";

	my $ssl = Net::SSLeay::new($ctx) or die("Failed to create SSL $!");
	Net::SSLeay::set_session($ssl, $ses) if defined $ses;
	Net::SSLeay::set_fd($ssl, fileno($s));
	Net::SSLeay::connect($ssl) or die("ssl connect");
	return ($s, $ssl);
}

###############################################################################