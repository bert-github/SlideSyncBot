#!/usr/bin/env perl
#
# This IRC 'bot looks for lines of the form "slideset: URL" and
# "[slide N]", where N is a number. Case doesn't matter. When it sees
# the former, it replies with that URL with a sync server appended.
# E.g., when it sees:
#
#    slideset: https://example.org/slides
#
# It replies with some text and a new URL:
#
#   If the slideset... https://example.org/slides?sync=https://example.com/sse
#
# When it sees "[slide N]", it sends a message to that sync server.
# The sync server is then supposed to send a message to any browser
# that displays the slideset to ask it to show slide N.
#
# More documentation at the end in perlpod format.
#
# Created: 2022-11-17
# Author: Bert Bos <bert@w3.org>
#
# Copyright © 2022 World Wide Web Consortium, (Massachusetts Institute
# of Technology, European Research Consortium for Informatics and
# Mathematics, Keio University, Beihang). All Rights Reserved. This
# work is distributed under the W3C® Software License
# (http://www.w3.org/Consortium/Legal/2015/copyright-software-and-document)
# in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.

package SlideSyncBot;
use FindBin;
use lib "$FindBin::Bin";	# Look for modules in this file's directory
use parent 'Bot::BasicBot::ExtendedBot';
use strict;
use warnings;
# use feature 'state';
use POE::Session;
use LWP;
use LWP::ConnCache;
use HTTP::Status qw(:is status_message);
use Getopt::Std;
use POSIX qw(strftime);
use Scalar::Util 'blessed';
use Encode qw(encode decode);
use Term::ReadKey;		# To read a password without echoing
use utf8;
use open ':encoding(UTF-8)';	# Open all files assuming they are UTF-8

use constant HOME => '[not-yet-defined]';
use constant MANUAL => '[not-yet-defined';
use constant VERSION => '0.1';


# init -- initialize some parameters
sub init($)
{
  my $self = shift;
  my $errmsg;

  $self->{status} = {};		# Last GET results for each channel
  $self->{syncserver} = {};	# Per-channel sync server URLs
  $errmsg = $self->read_rejoin_list() and die "$errmsg\n";
  $self->log("Connecting...");
  return 1;
}


# get -- get the contents of a file by its URL
sub get($$)
{
  my ($self, $uri) = @_;
  my $ua;

  $ua = LWP::UserAgent->new;
  $ua->ssl_opts(verify_hostname => $self->{ssl_verify_hostname});
  $ua->agent(blessed($self) . '/' . VERSION);
  # $ua->timeout(10);
  $ua->conn_cache(LWP::ConnCache->new);
  $ua->env_proxy;
  return $ua->get($uri);
}


# invited -- handle an invitation to a channel
sub invited($$)
{
  my ($self, $info) = @_;
  my $who = $info->{who};
  my $raw_nick = $info->{raw_nick};
  my $channel = $info->{channel};

  $self->log("Invited by $who ($raw_nick) to $channel");
  $self->join_channel($channel);
  return;
}


# remember_channel -- update the list of joined channels on disk, if needed
sub remember_channel($$)
{
  my ($self, $channel) = @_;

  return if !$self->{rejoinfile}; # Not remembering channels
  $channel = lc $channel;
  return if exists $self->{joined_channels}->{$channel}; # Already remembered
  $self->{joined_channels}->{$channel} = 1;
  if (open my $fh, ">", $self->{rejoinfile}) {
    print $fh "$_\n" foreach keys %{$self->{joined_channels}};
  }
}


# forget_channel -- update the list of joined channels on disk, if needed
sub forget_channel($$)
{
  my ($self, $channel) = @_;

  return if !$self->{rejoinfile}; # Not remembering channels
  $channel = lc $channel;
  if (delete $self->{joined_channels}->{$channel}) { # Forget the channel
    if (open my $fh, ">", $self->{rejoinfile}) { # Can write file
      print $fh "$_\n" foreach keys %{$self->{joined_channels}};
    }
  }
}


# handle_slideset -- suggest a URL to play the slides in sync
sub handle_slideset($$$)
{
  my ($self, $info, $slideurl) = @_;
  my $channel = $info->{channel}; # "#channel" or "msg"
  my $id = $channel =~ tr/#&/01/r;

  return if $channel eq "msg";
  $self->log("Saw slideset: $slideurl");
  $slideurl =~ /^(.*?)(\?.*?)?(#.*)?$/;
  $slideurl = $1 . ($2 ? "$2&" : "?") .
      "sync=$self->{syncserver}->{$channel}/$id" . ($3//"");
  $self->{status}->{$channel} = undef;
  return "If the slideset uses b6+, -> try this to synchronize the slides to IRC $slideurl";
}


# request_slide_sync_process -- background process to make a GET request
sub request_slide_sync_process($$$$)
{
  my ($body, $self, $channel, $url) = @_;

  printf "%s %s %d\n", $channel, $url, $self->get($url)->code;
}


# request_slide_sync_handler -- handle output of request_slide_sync_process
sub request_slide_sync_handler($$$)
{
  my ($self, $body, $wheel_id) = @_[OBJECT, ARG0, ARG1];

  $body = decode('UTF-8', $body);
  my ($channel, $url, $code) = split ' ', $body;
  $self->{status}->{$channel} = $code;
  $self->log("Result $url --> $code");
}


# request_slide_sync -- send a sync request to the slide sync server
sub request_slide_sync($$$)
{
  my ($self, $info, $slide) = @_;
  my $channel = $info->{channel}; # "#channel" or "msg"
  my $id = $channel =~ tr/#&/01/r;
  my $url;
  my $code;

  return if $channel eq "msg";
  $url = "$self->{syncserver}->{$channel}/$id?page=$slide";
  $self->log("Requesting $url");

  $self->forkit(
    run => \&request_slide_sync_process,
    handler => "request_slide_sync_handler",
    arguments => [$self, $channel, $url]);

  return;
}


# handle_use_command -- change to a different sync server
sub handle_use_command($$$)
{
  my ($self, $info, $url) = @_;
  my $channel = $info->{channel}; # "#channel" or "msg"

  $self->{syncserver}->{$channel} = $url;
  $self->log("Sync server for $channel is now $url");
  return "OK";
}


# handle_status_command -- respond with our current status
sub handle_status_command($$)
{
  my ($self, $info) = @_;
  my $channel = $info->{channel};	# "#channel" or "msg"
  my $status;

  $status = "the sync server is " . $self->{syncserver}->{$channel};
  if ($self->{status}->{$channel}) {
      $status .= " and its last response was: " .
	  status_message($self->{status}->{$channel});
  }
  return $status;
}


# said -- handle a message
sub said($$)
{
  my ($self, $info) = @_;
  my $who = $info->{who};		# Nick (without the "!domain" part)
  my $text = $info->{body};		# What Nick said
  my $channel = $info->{channel};	# "#channel" or "msg"
  my $me = $self->nick();		# Our own name
  my $addressed = $info->{address};	# Defined if we're personally addressed

  return $self->handle_slideset($info, $1)
      if $text =~ /^ *slideset *: *(.+)$/i;

  return $self->request_slide_sync($info, $1)
      if $text =~ /^ *\[ *slide *([0-9]+|\+\+|[$^-]) *\] *$/i;

  # We don't handle other text unless it is addressed to us.
  return $self->SUPER::said($info)
      if !$addressed;

  # Remove the optional initial "please".
  $text =~ s/^please\s*,?\s*//i;

  return $self->handle_use_command($info, $1)
      if $text =~ /^ *use +(https?:\/\/[^ ]+) *$/i;

  return "That doesn't look like the URL of a sync server: $1"
      if $text =~ /^ *use +(.*?) *$/i;

  # Remove a final period or question mark
  $text =~ s/[.?] *$//;

  return $self->handle_status_command($info)
      if $text =~ /^ *status *$/;

  return $self->part_channel($channel),
      $self->forget_channel($channel), undef # undef -> no reply
      if $text =~ /^bye$/i;

  return $self->help($info)
      if $text =~ /^help/i;

  return "Sorry, I don't understand \"$text\". Try \"help\"."
      if $channel eq 'msg';	# Omit "$me" in a private channel.

  return "sorry, I don't understand \"$text\". Try \"$me, help\".";
}


# help -- handle a "syslibot, help" message
sub help($$)
{
  my ($self, $info) = @_;

  return "[todo]";
}


# chanjoin -- called when somebody joins a channel
sub chanjoin($$)
{
  my ($self, $info) = @_;
  my $channel = $info->{channel}; # "#channel" or "msg"
  my $who = $info->{who};

  if ($who eq $self->nick) {
    $self->log("Joined $channel");
    $self->{syncserver}->{$channel} = $self->{default_syncserver};
    $self->{status}->{$channel} = undef;
    $self->remember_channel($channel);
  }
  return;
}


# connected -- log a successful connection
sub connected($)
{
  my ($self) = @_;

  $self->join_channel($_) foreach keys %{$self->{joined_channels}};
}


# log -- print a message to STDERR, but only if -v (verbose) was specified
sub log
{
  my ($self, @messages) = @_;

  if ($self->{'verbose'}) {
    # Prefix all log lines with the current time, unless the line
    # already starts with a time.
    #
    my $now = strftime "%Y-%m-%dT%H:%M:%SZ", gmtime;
    $self->SUPER::log(
      map /^\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ/ ? $_ : "$now $_", @messages);
  }
}


# read_rejoin_list -- read or create the rejoin file, if any
sub read_rejoin_list($)
{
  my $self = shift;

  $self->{joined_channels} = {};
  if ($self->{rejoinfile}) {	# Option -r was given
    if (-f $self->{rejoinfile}) { # File exists
      $self->log("Reading $self->{rejoinfile}");
      open my $fh, "<", $self->{rejoinfile} or
	  return "$self->{rejoinfile}: $!\n";
      while (<$fh>) {chomp; $self->{joined_channels}->{lc $_} = 1;}
    } else {			# File does not exist yet
      $self->log("Creating $self->{rejoinfile}");
      open my $fh, ">", $self->{rejoinfile} or
	  return "$self->{rejoinfile}: $!\n";
    }
  }
  return undef;			# No errors
}


# Main body

my (%opts, $ssl, $user, $password, $host, $port, $channel);

$Getopt::Std::STANDARD_HELP_VERSION = 1;
getopts('C:kn:N:r:v', \%opts) or die "Try --help\n";

# The arguments must be an IRC-URL and the URL of a sync server.
#
die "Usage: $0 [options] [--help] IRC-URL sync-URL\n" if $#ARGV != 1;
($ssl, $user, $password, $host, $port, $channel) =
    $ARGV[0] =~ m/^(ircs?):\/\/(?:([^:]+):([^@]+)?@)?([^:\/#?]+)(?::([^\/]*))?(?:\/(.+)?)?$/i or
    die "First argument must be a URI starting with `irc:' or `ircs:'\n";
$ssl = $ssl eq 'ircs';
$user =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $user;
$password =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $password;
$port //= $ssl ? 6697 : 6667;
$channel =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg if defined $channel;
$channel = "#$channel" if defined $channel && $channel !~ /^[#&]/;
# TODO: Do something with other parameters, such as a key
if (defined $user && !defined $password) {
  print "IRC password for user \"$user\": ";
  ReadMode('noecho');
  $password = ReadLine(0);
  ReadMode('restore');
  print "\n";
}

my $bot = SlideSyncBot->new(
  server => $host,
  port => $port,
  ssl => $ssl,
  charset => $opts{'C'} // 'utf8',
  username => $user,
  password => $password,
  nick => $opts{'n'} // 'syslibot',
  name => $opts{'N'} // 'SlideSyncBot '.VERSION.' '.HOME,
  channels => (defined $channel ? [$channel] : []),
  rejoinfile => $opts{'r'},
  verbose => defined $opts{'v'},
  default_syncserver => $ARGV[1],
  ssl_verify_hostname => $opts{'k'} ? 0 : 1);

$bot->run();



=encoding utf8

=head1 NAME

slidesyncbot - IRC 'bot to help synschronize slide displays in browsers

=head1 SYNOPSIS

slidesyncbot [-n I<nick>] [-N I<name>] [-r rejoin-file] [-C charset]
[-k] [-v] I<IRC-URL> I<sync-URL>

=head1 DESCRIPTION

Slidesyncbot works together with a JavaScript slide framework such as
b6+ and a Server-Sent Events server such as sse-server(1) to
synchronize multiple browsers that display the same HTML slide set.
Commands on IRC determine which slide is displayed. E.g., a line such
as C<[slide 6]> on IRC directs all browsers to display the 6th slide.

Slidesyncbot is called with two URLs. The first identifies the IRC
server that the slidesyncbot should join, the second the HTTP server
that will be used to distribute events to browsers.

The first URL must start with B<irc:> or B<ircs:>. A full URL looks
like this:

=over

B<ircs://>I<login>B<:>I<password>B<@>I<host>B</>I<channel>

=back

The parts are:

=over

=item

I<host> is the hostname of an IRC server.

=item

I<login> is the user name with which to authenticate to the server. If
the server does not require authentication, the part
I<login>B<:>I<password>B<@> can be omitted.

=item

The password can also be left empty, in which case slidesyncbot will prompt
for the password.

=item

I<channel> is the name of a channel to join. If it doesn't start with
a hash mark (#), slidesyncbot will implicitly add one. The channel can
be omitted, in which case slidesyncbot will not join a channel, but
only connect to the IRC server and wait to be invited to a channel.
(See also the B<-r> option for more ways to join channels on startup.)

=back

The second URL must point to an HTTP server that can distribute
Server-Side Events (SSE). It is assumed to work like sse-server(1).
Which means if its URL is C<https://example.org/sse>, then web clients
can subscribe to a "channel" called C<myevents> by requesting the URL
C<https://example.org/sse/myevents>. And slidesyncbot can send
synchronization messages to that channel my requesting a URL like
C<https://example.org/sse/myevents?page=3>.

On IRC, slidesyncbot is usually known by the nickname "syslibot"
(unless changed by the B<-n> option when slidesyncbot was started).

Slidesyncbot recognizes the following commands in IRC:

=over

=item B</invite syslibot>

This command asks slidesyncbot to join the current channel.

=item B<slideset:> I<slide-URL>

The I<slide-URL> is assumed to point to a slide set that has support
for remote synchronization. In particular, if the query
B<?sync=>I<sync-URL> is added after the URL, the slide set is expected
to connect to that URL to get synchronization messages. (Typically,
this means that the slide set uses JavaScript with code that calls
HTML5's EventSource functions.) One slide framework that has support
for synchronization like this is b6+.

Slidesyncbot responds on IRC with the slideset URL with the query
appended (i.e., I<slide-URL>?sync=I<sync-URL>). Users who want to
follow the slide presentation must themselves copy this URL to their
browser. In some IRC clients, clicking on the URL also works.

=item B<[slide >I<N>B<]>

I<N> must be a number. Whenever it sees a line like this, slidesyncbot
sends a message to the synchronization server. The synchronization
server in turn will send messages to all connected browsers and ask
them to display slide number I<N>. The square brackets are part of the
command and are required. Spaces are allowed around and inside the
brackets.

=item B<syslibot, use> I<sync-URL>

Slidesyncbot can use different synchronization servers on different
channels. By default, it uses the server that was given on the command
line when it was started. This command instructs slidesyncbot to use
the given URL instead, but only on the current channel.

Slidesyncbot does not remember the URL when it leaves the channel. The
next time it joins, it will again use the default synchronization
server.

=item B<syslibot, status>

Slidesyncbot responds with some information: the synchronization
server in use and the last response from that server, if any. (That
response should be "OK". Any other response probably means that the
server isn't working properly.)

=item B<syslibot, bye>

This tells slidesyncbot to leave the channel.

=item B<help>

Slidesyncbot responds with some information about the commands that it
understands.


=back

=head1 OPTIONS

Slidesyncbot accepts the following options on the command line:

=over

=item B<-n> I<nick>

The nickname of the bot on IRC. Default is "syslibot".

=item B<-N> I<name>

The "real name" of the bot. Default is "SlideSyncBot".

=item B<-r> I<rejoin-file>

If the option B<-r> is given, syncslidebot joins the channels in
I<rejoin-file> as soon as it connects to the server, without having to
be invited. It updates the file when it is invited to an additional
channel or is dismissed from one. This way, when syncslidebot is
stopped and then restarted (with the same B<-r> option), it will
automatically rejoin the channels it was on when it was stopped.

=item B<C> I<charset>

Set the character encoding for messages. This should match what the
IRC server expects. The default is utf8.

=item B<-v>

Be verbose. Makes the 'bot print a log to standard error output of
what it is doing.

=item B<-k>

Turns off hostname verification if the sync server is using a
self-signed SSL certificate or another unrecognized certificate. Not
recommended.

=back

=head1 BUGS

Slidesyncbot does not check if a given slide set actually supports
synchronization. If the slide set does not support synchronization,
the URL that slidesyncbot suggests and the messages that it sends to
the synchronization server will not work, but will probably do no harm
either.

Also, slidesyncbot does not verify that messages to the
synchronization server are actually delivered. The B<status> command
can be used to see what the synchronization server responded, and if
verbose mode (B<-v>) is on, the response code is also printed to
stderr, but slidesyncbot itself does not do anything with that
response.

=head1 NOTES

None.

=head1 AUTHOR

Bert Bos E<lt>bert@w3.orgE<gt>

=head1 SEE ALSO

L<sse-server(1)>,
L<b6+|https://www.w3.org/Talk/Tools/b6plus/>
L<Server-Sent Events in HTML|https://html.spec.whatwg.org/multipage/server-sent-events.html>,
L<EventSource API|https://developer.mozilla.org/en-US/docs/Web/API/EventSource>,
L<Agendabot|https://www.w3.org/Tools/AgendaBot/manual.html>,
L<Zakim|https://www.w3.org/2001/12/zakim-irc-bot.html>,
L<RRSAgent|https://www.w3.org/2002/03/RRSAgent>,
L<scribe.perl|https://dev.w3.org/2002/scribe2/scribedoc>

=cut
