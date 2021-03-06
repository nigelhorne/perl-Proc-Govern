package Proc::Govern;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(govern_process);

our %SPEC;

use Time::HiRes qw(sleep);

sub new {
    my ($class) = @_;
    bless {}, $class;
}

sub _suspend {
    my $self = shift;
    my $h = $self->{h};
    say "D:Suspending program ..." if $self->{debug};
    if (@{ $h->{KIDS} }) {
        my @args = (STOP => (map { $_->{PID} } @{ $h->{KIDS} }));
        if ($self->{args}{killfam}) {
            #say "D:killfam ".join(" ", @args) if $self->{debug};
            Proc::Killfam::killfam(@args);
        } else {
            #say "D:kill ".join(" ", @args) if $self->{debug};
            kill @args;
        }
    }
    $self->{suspended} = 1;
}

sub _resume {
    my $self = shift;
    my $h = $self->{h};
    say "D:Resuming program ..." if $self->{debug};
    if (@{ $h->{KIDS} }) {
        my @args = (CONT => (map { $_->{PID} } @{ $h->{KIDS} }));
        if ($self->{args}{killfam}) {
            #say "D:killfam ".join(" ", @args) if $self->{debug};
            Proc::Killfam::killfam(@args);
        } else {
            #say "D:kill ".join(" ", @args) if $self->{debug};
            kill @args;
        }
    }
    $self->{suspended} = 0;
}

sub _kill {
    my $self = shift;
    my $h = $self->{h};
    $self->_resume if $self->{suspended};
    say "D:Killing program ..." if $self->{debug};
    $self->{restart} = 0;
    $h->kill_kill;
}

$SPEC{govern_process} = {
    v => 1.1,
    summary => 'Run child process and govern its various aspects',
    description => <<'_',

It basically uses <pm:IPC::Run> and a loop to check various conditions during
the lifetime of the child process.

TODO: restart_delay, check_alive.

_
    args => {
        name => {
            schema => 'str*',
            description => <<'_',

Should match regex `\A\w+\z`. Used in several places, e.g. passed as `prefix` in
<pm:File::Write::Rotate>'s constructor as well as used as name of PID file.

If not given, will be taken from command.

_
        },
        command => {
            schema => ['array*' => of => 'str*'],
            req => 1,
            summary => 'Command to run',
            description => <<'_',

Passed to <pm:IPC::Run>'s `start()`.

_
        },
        single_instance => {
            schema => [bool => default => 0],
            description => <<'_',

If set to true, will prevent running multiple instances simultaneously.
Implemented using <pm:Proc::PID::File>. You will also normally have to set
`pid_dir`, unless your script runs as root, in which case you can use the
default `/var/run`.

_
            tags => ['category:instance-control'],
        },
        pid_dir => {
            summary => 'Directory to put PID file in',
            schema => 'str*',
        },
        on_multiple_instance => {
            schema => ['str*' => in => ['exit']],
            description => <<'_',

Can be set to `exit` to silently exit when there is already a running instance.
Otherwise, will print an error message `Program <NAME> already running`.

_
            tags => ['category:instance-control'],
        },
        load_watch => {
            schema => [bool => default => 0],
            description => <<'_',

If set to 1, enable load watching. Program will be suspended when system load is
too high and resumed if system load returns to a lower limit.

_
        },
        load_check_every => {
            schema => [duration => default => 10],
            summary => 'Frequency of load checking',
            tags => ['category:load-control'],
        },
        load_high_limit => {
            schema => ['any*' => of => [[int => default => 1.25], 'code*']],
            description => <<'_',

Limit above which program should be suspended, if load watching is enabled. If
integer, will be compared against <pm:Unix::Uptime>`->load`'s `$load1` value.
Alternatively, you can provide a custom routine here, code should return true if
load is considered too high.

_
            tags => ['category:load-control'],
        },
        load_low_limit => {
            schema => ['any*' => of => [[int => default => 0.25], 'code*']],
            description => <<'_',

Limit below which program should resume, if load watching is enabled. If
integer, will be compared against <pm:Unix::Uptime>`->load`'s `$load1` value.
Alternatively, you can provide a custom routine here, code should return true if
load is considered low.

_
            tags => ['category:load-control'],
        },
        killfam => {
            summary => 'Instead of kill, use killfam (kill family of process)',
            schema  => 'bool',
            description => <<'_',

This can be useful e.g. to control load more successfully, if the
load-generating processes are the subchildren of the one we're governing.

This requires <pm:Proc::Killfam> CPAN module, which is installed separately.

_
        },
        log_stdout => {
            summary => 'Will be passed as arguments to `File::Write::Rotate`',
            schema => ['hash*' => keys => {
                dir       => 'str*',
                size      => 'str*',
                histories => 'int*',
            }],
            tags => ['category:logging'],
        },
        show_stdout => {
            schema => [bool => default => 1],
            summary => 'Just like `show_stderr`, but for STDOUT',
            tags => ['category:output-control'],
        },
        log_stderr => {
            summary => 'Will be passed as arguments to `File::Write::Rotate`',
            description => <<'_',

Specify logging for STDERR. Logging will be done using <pm:File::Write::Rotate>.
Known hash keys: `dir` (STR, defaults to `/var/log`, directory, preferably
absolute, where the log file(s) will reside, should already exist and be
writable, will be passed to <pm:File::Write::Rotate>'s constructor), `size`
(int, also passed to <pm:File::Write::Rotate>'s constructor), `histories` (int,
also passed to <pm:File::Write::Rotate>'s constructor), `period` (str, also
passed to <pm:File::Write::Rotate>'s constructor).

_
            schema => ['hash*' => keys => {
                dir       => 'str*',
                size      => 'str*',
                histories => 'int*',
            }],
            tags => ['category:logging'],
        },
        show_stderr => {
            schema => ['bool'],
            default => 1,
            description => <<'_',

Can be used to turn off STDERR output. If you turn this off and set
`log_stderr`, STDERR output will still be logged but not displayed to screen.

_
            tags => ['category:output-control'],
        },
        timeout => {
            schema => ['int*'],
            summary => 'Apply execution time limit, in seconds',
            description => <<'_',

After this time is reached, process (and all its descendants) are first sent the
TERM signal. If after 30 seconds pass some processes still survive, they are
sent the KILL signal.

The killing is implemented using <pm:IPC::Run>'s `kill_kill()`.

Upon timeout, exit code is set to 124.

_
            tags => ['category:timeout'],
        },
        restart => {
            schema => [bool => default => 1],
            summary => 'If set to true, do restart',
            tags => ['category:restart'],
        },
        # not yet defined
        #restart_delay => {
        #    schema => ['duration*', default=>0],
        #    tags => ['category:restart'],
        #},
        #check_alive => {
        #    # not yet defined, can supply a custom coderef, or specify some
        #    # standard checks like TCP/UDP connection to some port, etc.
        #    schema => 'any*',
        #},
        no_screensaver => {
            summary => 'Prevent screensaver from being activated',
            schema => ['bool*', is=>1],
            tags => ['category:screensaver'],
        },
    },
    args_rels => {
        'dep_all&' => [
            [pid_dir => ['single_instance']],
            [load_low_limit   => ['load_watch']], # XXX should only be allowed when load_watch is true
            [load_high_limit  => ['load_watch']], # XXX should only be allowed when load_watch is true
            [load_check_every => ['load_watch']], # XXX should only be allowed when load_watch is true
         ],

    },
    result_naked => 1,
    result => {
        summary => "Child's exit code",
        schema => 'int',
    },
};
sub govern_process {
    my $self;
    if (ref $_[0]) {
        $self = shift;
    } else {
        $self = __PACKAGE__->new;
    }

    my %args = @_;
    $self->{args} = \%args;

    require Proc::Killfam if $args{killfam};
    require Screensaver::Any if $args{no_screensaver};

    my $debug = $ENV{DEBUG};
    $self->{debug} = $debug;

    my $exitcode;

    my $cmd = $args{command};
    defined($cmd) or die "Please specify command\n";
    ref($cmd) eq 'ARRAY' or die "Command must be arrayref of strings";

    my $name = $args{name};
    if (!defined($name)) {
        $name = $cmd->[0];
        $name =~ s!.*/!!; $name =~ s/\W+/_/g;
        length($name) or $name = "prog";
    }
    defined($name) or die "Please specify name\n";
    $name =~ /\A\w+\z/ or die __PACKAGE__, ": Invalid name, please use letters/numbers only";
    $self->{name} = $name;

    if ($args{single_instance}) {
        my $pid_dir = $args{pid_dir} // "/var/run";
        require Proc::PID::File;
        if (Proc::PID::File->running(dir=>$pid_dir, name=>$name, verify=>1)) {
            if ($args{on_multiple_instance} &&
                    $args{on_multiple_instance} eq 'exit') {
                $exitcode = 202; goto EXIT;
            } else {
                warn "Program $name already running\n";
                $exitcode = 202; goto EXIT;
            }
        }
    }

    my $showout = $args{show_stdout} // 1;
    my $showerr = $args{show_stderr} // 1;

    my $lw     = $args{load_watch} // 0;
    my $lwfreq = $args{load_check_every} // 10;
    my $lwhigh = $args{load_high_limit}  // 1.25;
    my $lwlow  = $args{load_low_limit}   // 0.25;

    my $noss   = $args{no_screensaver};

    ###

    my $out;
    if ($args{log_stdout}) {
        require File::Write::Rotate;
        my %fwrargs = %{$args{log_stdout}};
        $fwrargs{dir}    //= "/var/log";
        $fwrargs{prefix}   = $name;
        my $fwr = File::Write::Rotate->new(%fwrargs);
        $out = sub {
            print STDOUT $_[0]//'' if $showout;
            # XXX prefix with timestamp, how long script starts,
            $_[0] =~ s/^/STDOUT: /mg;
            $fwr->write($_[0]);
        };
    } else {
        $out = sub {
            print STDOUT $_[0]//'' if $showout;
        };
    }

    my $err;
    if ($args{log_stderr}) {
        require File::Write::Rotate;
        my %fwrargs = %{$args{log_stderr}};
        $fwrargs{dir}    //= "/var/log";
        $fwrargs{prefix}   = $name;
        my $fwr = File::Write::Rotate->new(%fwrargs);
        $err = sub {
            print STDERR $_[0]//'' if $showerr;
            # XXX prefix with timestamp, how long script starts,
            $_[0] =~ s/^/STDERR: /mg;
            $fwr->write($_[0]);
        };
    } else {
        $err = sub {
            print STDERR $_[0]//'' if $showerr;
        };
    }

    my $start_time; # for timeout
    my ($to, $h);

    my $do_start = sub {
        $start_time = time();
        require IPC::Run;
        say "D:(Re)starting program $name ..." if $debug;
        $to = IPC::Run::timeout(1);
        #$self->{to} = $to;
        $h  = IPC::Run::start($cmd, \*STDIN, $out, $err, $to)
            or die "Can't start program: $?\n";
        $self->{h} = $h;
    };

    $do_start->();

    local $SIG{INT} = sub {
        say "D:Received INT signal" if $debug;
        $self->_kill;
        exit 1;
    };

    local $SIG{TERM} = sub {
        say "D:Received TERM signal" if $debug;
        $self->_kill;
        exit 1;
    };

    my $chld_handler;
    $self->{restart} = $args{restart};
    $chld_handler = sub {
        $SIG{CHLD} = $chld_handler;
        if ($self->{restart}) {
            say "D:Child died" if $debug;
            $do_start->();
        }
    };
    local $SIG{CHLD} = $chld_handler if $args{restart};

    my $lastlw_time;
    my ($noss_screensaver, $noss_timeout, $noss_lastprevent_time);

  MAIN_LOOP:
    while (1) {
        #say "D:main loop" if $debug;
        if (!$self->{suspended}) {
            # re-set timer, it might be reset by suspend/resume?
            $to->start(1);

            unless ($h->pumpable) {
                $h->finish;
                $exitcode = $h->result;
                last MAIN_LOOP;
            }

            eval { $h->pump };
            my $everr = $@;
            die $everr if $everr && $everr !~ /^IPC::Run: timeout/;
        } else {
            sleep 1;
        }
        my $now = time();

        if (defined $args{timeout}) {
            if ($now - $start_time >= $args{timeout}) {
                $err->("Timeout ($args{timeout}s), killing child ...\n");
                $self->_kill;
                # mark with a special exit code that it's a timeout
                $exitcode = 124;
                last MAIN_LOOP;
            }
        }

        if ($lw && (!$lastlw_time || $lastlw_time <= ($now-$lwfreq))) {
            say "D:Checking load" if $debug;
            if (!$self->{suspended}) {
                my $is_high;
                if (ref($lwhigh) eq 'CODE') {
                    $is_high = $lwhigh->($h);
                } else {
                    require Unix::Uptime;
                    my @load = Unix::Uptime->load();
                    $is_high = $load[0] >= $lwhigh;
                }
                if ($is_high) {
                    say "D:Load is too high" if $debug;
                    $self->_suspend;
                }
            } else {
                my $is_low;
                if (ref($lwlow) eq 'CODE') {
                    $is_low = $lwlow->($h);
                } else {
                    require Unix::Uptime;
                    my @load = Unix::Uptime->load();
                    $is_low = $load[0] <= $lwlow;
                }
                if ($is_low) {
                    say "D:Load is low" if $debug;
                    $self->_resume;
                }
            }
            $lastlw_time = $now;
        }

      NOSS:
        {
            last unless $noss;
            last unless !$noss_lastprevent_time ||
                $noss_lastprevent_time <= ($now-$noss_timeout+5);
            say "D:Preventing screensaver from activating" if $debug;
            if (!$noss_lastprevent_time) {
                $noss_screensaver = Screensaver::Any::detect_screensaver();
                if (!$noss_screensaver) {
                    warn "Can't detect any known screensaver, ".
                        "will skip preventing screensaver from activating\n";
                    $noss = 0;
                    last NOSS;
                }
                my $res = Screensaver::Any::get_screensaver_timeout(
                    screensaver => $noss_screensaver,
                );
                if ($res->[0] != 200) {
                    warn "Can't get screensaver timeout ($res->[0]: $res->[1])".
                        ", will skip preventing screensaver from activating\n";
                    $noss = 0;
                    last NOSS;
                }
                $noss_timeout = $res->[2];
            }
            my $res = Screensaver::Any::prevent_screensaver_activated(
                screensaver => $noss_screensaver,
            );
            if ($res->[0] != 200) {
                warn "Can't prevent screensaver from activating ".
                    "($res->[0]: $res->[1])\n";
            }
            $noss_lastprevent_time = $now;
        }

    } # MAINLOOP

  EXIT:
    return $exitcode || 0;
}

1;
# ABSTRACT:

=for Pod::Coverage ^(new)$

=head1 SYNOPSIS

To use via command-line (in most cases):

 % govproc \
       --timeout 3600 \
       --log-stderr-dir        /var/log/myapp/ \
       --log-stderr-size       16M \
       --log-stderr-histories  12 \
   /path/to/myapp

To use directly as Perl module:

 use Proc::Govern qw(govern_process);
 govern_process(
     name       => 'myapp',
     command    => ['/path/to/myapp', 'some', 'args'],
     timeout    => 3600,
     log_stderr => {
         dir       => '/var/log/myapp',
         size      => '16M',
         histories => 12,
     },
 );


=head1 DESCRIPTION

Proc::Govern is a child process manager. It is meant to be a convenient bundle
(a single parent/monitoring process) for functionalities commonly needed when
managing a child process. It comes with a command-line interface, L<govproc>.

Background story: I first created this module to record STDERR output of scripts
that I run from cron. The scripts already log debugging information using
L<Log::Any> to an autorotated log file (using L<Log::Dispatch::FileRotate>, via
L<Log::Any::Adapter::Log4perl>, via L<Log::Any::App>). However, when the scripts
warn/die, or when the programs that the scripts execute emit messages to STDERR,
they do not get recorded. Thus, every script is then run through B<govproc>.
From there, B<govproc> naturally gets additional features like timeout,
preventing running multiple instances, and so on.

Currently the following governing functionalities are available:

=over

=item * logging of STDOUT & STDERR output to an autorotated file

=item * execution time limit

=item * preventing multiple instances from running simultaneously

=item * load watch

=item * autorestart

=back

In the future the following features are also planned or contemplated:

=over

=item * CPU time limit

=item * memory limit

With an option to autorestart if process' memory size grow out of limit.

=item * other resource usage limit

=item * fork/start multiple processes

=item * set (CPU) nice level

=item * set I/O nice level (scheduling priority/class)

=item * limit STDIN input, STDOUT/STDERR output?

=item * trap/handle some signals for the child process?

=item * set UID/GID?

=item * provide daemon functionality?

=item * provide network server functionality?

Inspiration: djb's B<tcpserver>.

=item * set/clean environment variables

=back


=head1 EXIT CODES

Below is the list of exit codes that Proc::Govern uses:

=over

=item * 124

Timeout. The exit code is also used by B<timeout>.

=item * 202

Another instance is already running (when C<single_instance> option is true).

=back


=head1 ENVIRONMENT

=head2 DEBUG => bool

If set to true, will display debugging output to STDERR, e.g. when
stopping/starting a process.


=head1 FAQ

=head2 Why use Proc::Govern?

The main feature this module offers is convenience: it creates a single parent
process to monitor child process. This fact is more pronounced when you need to
monitor lots of child processes. If you use, on the other hand, separate
parent/monitoring process for timeout and then a separate one for CPU watching,
and so on, there will potentially be a lot more processes running on the system.
Compare for example:

 % govproc --timeout 10 --load-watch CMD

which only creates one monitoring process, versus:

 % timeout 10s loadwatch CMD

which will create two parent processes (three actually, B<loadwatch> apparently
forks first).


=head1 CAVEATS

Not yet tested on Win32.


=head1 SEE ALSO

Proc::Govern uses L<IPC::Run> at its core.

L<IPC::Cmd> also uses IPC::Run (as well as L<IPC::Open3> on systems that do not
have IPC::Run installed or on some archaic systems that do not support IPC::Run)
and its C<run_forked()> routine also has some of Proc::Govern's functionalities
like capturing stdout and stderr, timeout, hiding (discarding) output. If you
only need those functionalities, you can use IPC::Cmd as it is a core module.

Proc::Govern attempts (or will attempt, some day) to provide the functionality
(or some of the functionality) of the builtins/modules/programs listed below:

=over

=item * Starting/autorestarting

djb's B<supervise>, http://cr.yp.to/daemontools/supervise.html

=item * Pausing under high system load

B<loadwatch>. This program also has the ability to run N copies of program and
interactively control stopping/resuming via Unix socket.

cPanel also includes a program called B<cpuwatch>.

=item * Preventing multiple instances of program running simultaneously

L<Proc::PID::File>, L<Sys::RunAlone>

=item * Execution time limit

B<timeout>.

alarm() (but alarm() cannot be used to timeout external programs started by
system()/backtick).

L<Sys::RunUntil>

=item * Logging

djb's B<multilog>, http://cr.yp.to/daemontools/multilog.html

=back

Although not really related, L<Perinci::Sub::Wrapper>. This module also bundles
functionalities like timeout, retries, argument validation, etc into a single
function wrapper.

=cut
