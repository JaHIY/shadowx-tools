#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.010;
use autodie;

use Carp qw(croak);
use Encode qw(decode);
use FindBin;
use Getopt::Long ();
use HTTP::CookieJar;
use HTTP::Tiny;
use JSON ();
use Text::Trim qw(trim);
use URI;
use Web::Scraper;
use YAML ();

my $CONFIG_FILE = "${FindBin::RealBin}/config.yml";
my $USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64; rv:36.0) Gecko/20100101 Firefox/36.0';
my $BASE_URL = 'https://cattt.com';
my $BASE_URI = URI->new( $BASE_URL );

sub build_uri_path {
    my ( $uri, $path ) = @_;
    my $uri_clone = $uri->clone;
    $uri_clone->path( $path );
    return $uri_clone;
}

sub login {
    my ( $http, $account ) = @_;
    my $login_response = $http->post_form( build_uri_path( $BASE_URI, '/user/_login.php' ), {
            email => $account->{email},
            passwd => $account->{password},
            remember => 'week',
        }, {
            headers => {
                Referer => build_uri_path( $BASE_URI, '/user/login.php' ),
            },
        } );
    croak sprintf( 'Cannot login! (%d: %s)', $login_response->{status}, $login_response->{reason} ) if not $login_response->{success};
}

sub checkin {
    my ( $http ) = @_;
    my $checkin_response = $http->get( build_uri_path( $BASE_URI, '/user/_checkin.php' ), {
            headers => {
                'X-Requested-With' => 'XMLHttpRequest',
                Referer => build_uri_path( $BASE_URI, '/user/index.php' ),
            }
        } );
    croak sprintf( 'Cannot checkin! (%d: %s)', $checkin_response->{status}, $checkin_response->{reason} ) if not $checkin_response->{success};
    return JSON->new->utf8->decode( $checkin_response->{content} );
}

sub get_account_info {
    my ( $http ) = @_;
    my $account_info_response = $http->get( build_uri_path( $BASE_URI, '/user/index.php' ) );
    croak sprintf( 'Cannot get account info! (%d: %s)', $account_info_response->{status}, $account_info_response->{reason} ) if not $account_info_response->{success};
    my $scraper = scraper {
        process '.box', 'box[]' => scraper {
            process_first '.box-title', 'title' => [ 'TEXT', sub { trim } ];
            process '.box-body p:not(:empty)', 'body[]' => [ 'TEXT', sub { trim } ];
        };
    };
    my $res = $scraper->scrape( decode( 'utf8', $account_info_response->{content} ) );
    return $res->{box};
}

sub get_node_info {
    my ( $http ) = @_;
    my $node_info_response = $http->get( build_uri_path( $BASE_URI, '/user/node.php' ) );
    croak sprintf( 'Cannot get node info! (%d: %s)', $node_info_response->{status}, $node_info_response->{reason} ) if not $node_info_response->{success};
    my $scraper = scraper {
        process '.content-wrapper .col-md-6 > .box', 'node_lists[]' => scraper {
            process_first '.box-title', 'name' => [ 'TEXT', sub { trim } ];
            process '.nav-tabs-custom', 'nodes[]' => scraper {
                process_first '.header' , 'name' => [ 'TEXT', sub { trim } ];
                process_first '.tab-content code', 'address' => [ 'TEXT', sub { trim } ];
                process_first '.tab-content .bg-orange', 'status' => [ 'TEXT', sub { trim } ];
                process_first '.tab-content .bg-green', 'method' => [ 'TEXT', sub { trim } ];
                process_first '.tab-content p:last-child', 'description' => [ 'TEXT', sub { trim } ];
            };
        };
    };
    my $res = $scraper->scrape( decode( 'utf8', $node_info_response->{content} ) );
    return $res->{node_lists};
}

sub get_sys_info {
    my ( $http ) = @_;
    my $sys_info_response = $http->get( build_uri_path( $BASE_URI, '/user/sys.php' ) );
    croak sprintf( 'Cannot get sys info! (%d: %s)', $sys_info_response->{status}, $sys_info_response->{reason} ) if not $sys_info_response->{success};
    my $scraper = scraper {
        process '.box-body > p', 'sys[]' => [ 'TEXT', sub { trim } ];
    };
    my $res = $scraper->scrape( decode( 'utf8', $sys_info_response->{content} ) );
    return $res->{sys};
}

sub main {
    binmode *STDIN,  ':encoding(utf8)';
    binmode *STDOUT, ':encoding(utf8)';
    binmode *STDERR, ':encoding(utf8)';
    my $getopt_parser = Getopt::Long::Parser->new;
    my %option_of;

    croak 'Cannot parse options!' if not $getopt_parser->getoptionsfromarray(
        \@_,
        \%option_of,
        'checkin!',
        'account-info!',
        'node-info!',
        'sys-info!'
    );

    my $config = YAML::LoadFile( $CONFIG_FILE );
    my $cookie_jar = HTTP::CookieJar->new;
    my $http = HTTP::Tiny->new(
        agent => $USER_AGENT,
        cookie_jar => $cookie_jar
    );

    login( $http, $config->{account} );

    if ( defined $option_of{checkin} and $option_of{checkin} == 1 ) {
        say checkin( $http )->{msg};
        print "\n";
    }

    if ( defined $option_of{'account-info'} and $option_of{'account-info'} == 1 ) {
        my $account_info = get_account_info( $http );
        for my $box ( @{ $account_info } ) {
            say $box->{title};
            map { say $_ } @{ $box->{body} };
            print "\n";
        }
        print "\n";
    }

    if ( defined $option_of{'node-info'} and $option_of{'node-info'} == 1 ) {
        my $node_info = get_node_info( $http );
        my @fields = qw/name description address method status/;
        for my $node_list ( @{ $node_info } ) {
            next if not defined $node_list->{nodes};
            say $node_list->{name};
            for my $node ( @{ $node_list->{nodes} } ) {
                map { say $node->{ $_ } } @fields;
                print "\n";
            }
            print "\n";
        }
    }

    if ( defined $option_of{'sys-info'} and $option_of{'sys-info'} == 1 ) {
        my $sys_info = get_sys_info( $http );
        map { say $_ } @{ $sys_info };
        print "\n";
    }
}

main( @ARGV );
