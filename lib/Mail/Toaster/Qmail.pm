package Mail::Toaster::Qmail;
use strict;
use warnings;

our $VERSION = '5.53';

use Carp;
use English qw( -no_match_vars );
use File::Copy;
use File::Path;
use Params::Validate qw( :all );
use POSIX;
use Sys::Hostname;

use lib 'lib';
use parent 'Mail::Toaster::Base';

sub build_pop3_run {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    $self->get_supervise_dir or return;

    my @lines = $self->toaster->supervised_do_not_edit_notice(1);

    if ( $self->conf->{pop3_hostname} eq 'qmail' ) {
        push @lines, $self->supervised_hostname_qmail( 'pop3' );
    };

#qmail-popup mail.cadillac.net /usr/local/vpopmail/bin/vchkpw qmail-pop3d Maildir 2>&1
    my $exec = $self->toaster->supervised_tcpserver( 'pop3' ) or return;
    my $chkpass = $self->_set_checkpasswd_bin( prot => 'pop3' ) or return;

    $exec .= "\\\n\tqmail-popup ";
    $exec .= $self->toaster->supervised_hostname( "pop3" );
    $exec .= "$chkpass qmail-pop3d Maildir ";
    $exec .= $self->toaster->supervised_log_method( "pop3" );

    push @lines, $exec;

    my $file = '/tmp/toaster-watcher-pop3-runfile';
    $self->util->file_write( $file, lines => \@lines ) or return;
    $self->install_supervise_run( tmpfile => $file, prot => 'pop3' ) or return;
    return 1;
}

sub build_send_run {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    my %args = $self->get_std_args( %p );

    $self->audit( "generating send/run..." );

    $self->get_supervise_dir or return;

    my $mailbox  = $self->conf->{send_mailbox_string} || './Maildir/';
    my $send_log = $self->conf->{send_log_method}     || 'syslog';

    my @lines = $self->toaster->supervised_do_not_edit_notice;

    if ( $send_log eq 'syslog' ) {
        push @lines, "# use splogger to qmail-send logs to syslog\n
# make changes in /usr/local/etc/toaster-watcher.conf
exec qmail-start $mailbox splogger qmail\n";
    }
    else {
        push @lines, "# sends logs to multilog as directed in log/run
# make changes in /usr/local/etc/toaster-watcher.conf
exec qmail-start $mailbox 2>&1\n";
    }

    my $file = "/tmp/toaster-watcher-send-runfile";
    $self->util->file_write( $file, lines => \@lines, fatal => 0) or return;
    $self->install_supervise_run( tmpfile => $file, prot => 'send'  ) or return;
    return 1;
}

sub build_smtp_run {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    my %args = $self->toaster->get_std_args( %p );

    $self->audit( "generating supervise/smtp/run...");

    $self->_test_smtpd_config_values() or return;

    my $mem;

    my @smtp_run_cmd = $self->toaster->supervised_do_not_edit_notice(1);
    push @smtp_run_cmd, $self->smtp_set_qmailqueue();
    push @smtp_run_cmd, $self->smtp_get_simenv();

    $self->get_control_dir or return; # verify control directory exists
    $self->get_supervise_dir or return;

    push @smtp_run_cmd, $self->supervised_hostname_qmail( "smtpd" )
        if $self->conf->{'smtpd_hostname'} eq "qmail";

    push @smtp_run_cmd, $self->_smtp_sanity_tests();

    my $exec = $self->toaster->supervised_tcpserver( "smtpd" ) or return;
    $exec .= $self->smtp_set_rbls();
    $exec .= "\\\n\trecordio " if $self->conf->{'smtpd_recordio'};
    $exec .= "\\\n\tfixcrio "  if $self->conf->{'smtpd_fixcrio'};
    $exec .= "\\\n\tqmail-smtpd ";
    $exec .= $self->smtp_auth_enable();
    $exec .= $self->toaster->supervised_log_method( "smtpd" ) or return;

    push @smtp_run_cmd, $exec;

    my $file = '/tmp/toaster-watcher-smtpd-runfile';
    $self->util->file_write( $file, lines => \@smtp_run_cmd ) or return;
    $self->install_supervise_run( tmpfile => $file, prot => 'smtp' );
    return 1;
}

sub build_submit_run {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    my %args = $self->toaster->get_std_args( %p );

    return if ! $self->conf->{'submit_enable'};

    $self->audit( "generating submit/run...");

    return $self->error( "SMTPd config values failed tests!", %p )
        if ! $self->_test_smtpd_config_values();

    my $vdir = $self->setup->vpopmail->get_vpop_dir;

    $self->get_control_dir or return; # verify control directory exists
    $self->get_supervise_dir or return;

    # NOBADHELO note: don't subject authed clients to HELO tests since many
    # (Outlook, OE) do not send a proper HELO. -twa, 2007-03-07
    my @lines = (
            $self->toaster->supervised_do_not_edit_notice(1),
            $self->smtp_set_qmailqueue( prot => 'submit' ),
            qq{export NOBADHELO=""\n\n},
        );

    push @lines, $self->supervised_hostname_qmail( "submit" )
        if $self->conf->{'submit_hostname'} eq "qmail";
    push @lines, $self->_smtp_sanity_tests();

    my $exec = $self->toaster->supervised_tcpserver( "submit" ) or return;

    $exec .= "qmail-smtpd ";

    if ( $self->conf->{'submit_auth_enable'} ) {
        $exec .= $self->toaster->supervised_hostname( "submit" )
            if ( $self->conf->{'submit_hostname'} && $self->conf->{'qmail_smtpd_auth_0.31'} );

        my $chkpass = $self->_set_checkpasswd_bin( prot => 'submit' ) or return;
        $exec .= "$chkpass /usr/bin/true ";
    }

    $exec .= $self->toaster->supervised_log_method( "submit" ) or return;

    push @lines, $exec;

    my $file = '/tmp/toaster-watcher-submit-runfile';
    $self->util->file_write( $file, lines => \@lines ) or return;
    $self->install_supervise_run( tmpfile => $file, prot => 'submit' ) or return;
    return 1;
}

sub build_qmail_deliverable_run {
    my $self = shift;
    my $softlimit = $self->util->find_bin('softlimit');
    my $qmdd = $self->util->find_bin('qmail-deliverabled');

    my @lines = "#!/bin/sh
MAXRAM=50000000
exec $softlimit -m \$MAXRAM $qmdd -f 2>&1
";

    my $file = '/tmp/toaster-watcher-qmd-runfile';
    $self->util->file_write( $file, lines => \@lines ) or return;
    $self->install_supervise_run( tmpfile => $file, prot => 'qmail-deliverable' ) or return;
    return 1;
};

sub build_vpopmaild_run {
    my $self = shift;

    if ( ! $self->conf->{vpopmail_daemon} ) {
        $self->audit( "skipping vpopmaild/run" );
        return;
    };

    $self->audit( "generating vpopmaild/run..." );

    my $tcpserver = $self->util->find_bin('tcpserver');
    my $vpopdir = $self->setup->vpopmail->get_vpop_dir;

    my @lines = $self->toaster->supervised_do_not_edit_notice;
    push @lines, "#!/bin/sh
#exec 2>&1
exec 1>/dev/null 2>&1
exec $tcpserver -vHRD 127.0.0.1 89 $vpopdir/bin/vpopmaild
";

    my $file = '/tmp/toaster-watcher-vpopmaild-runfile';
    $self->util->file_write( $file, lines => \@lines, fatal => 0) or return;
    $self->qmail->install_supervise_run( tmpfile => $file, prot => 'vpopmaild' ) or return;
    return 1;
};

sub build_qpsmtpd_run {
    my $self = shift;
# unless/until there's not settings in toaster-watcher.conf, we'll assume the
# run file included with qpsmtpd is used
    return 1;
};

sub check_rcpthosts {
    my ($self) = @_;
    my $qmaildir = $self->get_qmail_dir;

    if ( !-d $qmaildir ) {
        $self->audit( "check_rcpthost: oops! the qmail directory does not exist!");
        return;
    }

    my $assign = "$qmaildir/users/assign";
    my $rcpt   = "$qmaildir/control/rcpthosts";
    my $mrcpt  = "$qmaildir/control/morercpthosts";

    # make sure an assign and rcpthosts file exists.
    unless ( -s $assign && -s $rcpt ) {
        $self->audit("check_rcpthost: $assign or $rcpt is missing!");
        return;
    }

    my @domains = $self->get_domains_from_assign;

    print "check_rcpthosts: checking your rcpthost files.\n.";
    my ( @f2, %rcpthosts, $domains, $count );

    # read in the contents of both rcpthosts files
    my @f1 = $self->util->file_read( $rcpt );
    @f2 = $self->util->file_read( $mrcpt )
      if ( -e "$qmaildir/control/morercpthosts" );

    # put their contents into a hash
    foreach ( @f1, @f2 ) { chomp $_; $rcpthosts{$_} = 1; }

    # and then for each domain in assign, make sure it is in rcpthosts
    foreach (@domains) {
        my $domain = $_->{'dom'};
        unless ( $rcpthosts{$domain} ) {
            print "\t$domain\n";
            $count++;
        }
        $domains++;
    }

    if ( ! $count || $count == 0 ) {
        print "Congrats, your rcpthosts is correct!\n";
        return 1;
    }

    if ( $domains > 50 ) {
        print
"\nDomains listed above should be added to $mrcpt. Don't forget to run 'qmail cdb' afterwards.\n";
    }
    else {
        print "\nDomains listed above should be added to $rcpt. \n";
    }
}

sub config {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );
    my %args = $self->toaster->get_std_args( %p );
    return $p{test_ok} if defined $p{test_ok};

    my $conf = $self->conf;
    my $host = $conf->{toaster_hostname};
       $host = hostname if $host =~ /(?:qmail|system)/;

    my $postmaster = $conf->{toaster_admin_email};
    my $ciphers    = $conf->{openssl_ciphers} || 'pci';

    if ( $ciphers =~ /^[a-z]+$/ ) {
        $ciphers = $self->setup->openssl_get_ciphers( $ciphers );
    };

    my @changes = (
        { file => 'control/me',                 setting => $host, },
        { file => 'control/concurrencyremote',  setting => $conf->{'qmail_concurrencyremote'},},
        { file => 'control/mfcheck',            setting => $conf->{'qmail_mfcheck_enable'},   },
        { file => 'control/tarpitcount',        setting => $conf->{'qmail_tarpit_count'},     },
        { file => 'control/tarpitdelay',        setting => $conf->{'qmail_tarpit_delay'},     },
        { file => 'control/spfbehavior',        setting => $conf->{'qmail_spf_behavior'},     },
        { file => 'alias/.qmail-postmaster',    setting => $postmaster,   },
        { file => 'alias/.qmail-root',          setting => $postmaster,   },
        { file => 'alias/.qmail-mailer-daemon', setting => $postmaster,   },
        { file => 'control/tlsserverciphers',   setting => $ciphers },
        { file => 'control/tlsclientciphers',   setting => $ciphers },
    );

    push @changes, $self->control_sql if $conf->{vpopmail_mysql};

    $self->config_write( \@changes );

    my $uid = getpwnam('vpopmail');
    my $gid = getgrnam('vchkpw');

    my $control = $self->get_control_dir;
    chown( $uid, $gid, "$control/servercert.pem" );
    chown( $uid, $gid, "$control/sql" );
    chmod oct('0640'), "$control/servercert.pem";
    chmod oct('0640'), "$control/clientcert.pem";
    chmod oct('0640'), "$control/sql";
    chmod oct('0644'), "$control/concurrencyremote";

    $self->config_freebsd if $OSNAME eq 'freebsd';

    # qmail control script (qmail cdb, qmail restart, etc)
    $self->control_create( %args );

    # create all the service and supervised dirs
    $self->toaster->service_dir_create( %args );
    $self->toaster->supervise_dirs_create( %args );

    # install the supervised control files
    $self->install_qmail_control_files( %args );
    $self->install_qmail_control_log_files( %args );
}

sub config_freebsd {
    my $self = shift;
    my $tmp  = $self->conf->{'toaster_tmp_dir'} || "/tmp";

    # disable sendmail
    $self->freebsd->conf_check(
        check => "sendmail_enable",
        line  => 'sendmail_enable="NONE"',
    );

    # don't build sendmail when we rebuild the world
    $self->util->file_write( "/etc/make.conf",
        lines  => ["NO_SENDMAIL=true"],
        append => 1,
    )
    if ! `grep NO_SENDMAIL /etc/make.conf`;

    # make sure mailer.conf is set up for qmail
    my $tmp_mailer_conf = "$tmp/mailer.conf";
    my $qmdir = $self->get_qmail_dir;
    my $maillogs = $self->util->find_bin('maillogs',fatal=>0 )
        || '/usr/local/bin/maillogs';
    open my $MAILER_CONF, '>', $tmp_mailer_conf
        or $self->error( "unable to open $tmp_mailer_conf: $!",fatal=>0);

    print $MAILER_CONF "
# \$FreeBSD: release/9.1.0/etc/mail/mailer.conf 93858 2002-04-05 04:25:14Z gshapiro \$
#
sendmail        $qmdir/bin/sendmail
send-mail       $qmdir/bin/sendmail
mailq           $maillogs yesterday
#mailq          $qmdir/bin/qmail-qread
newaliases      $qmdir/bin/newaliases
hoststat        $qmdir/bin/qmail-tcpto
purgestat       $qmdir/bin/qmail-tcpok
#
# Execute the \"real\" sendmail program, named /usr/libexec/sendmail/sendmail
#
#sendmail        /usr/libexec/sendmail/sendmail
#send-mail       /usr/libexec/sendmail/sendmail
#mailq           /usr/libexec/sendmail/sendmail
#newaliases      /usr/libexec/sendmail/sendmail
#hoststat        /usr/libexec/sendmail/sendmail
#purgestat       /usr/libexec/sendmail/sendmail

";

    $self->util->install_if_changed(
        newfile  => $tmp_mailer_conf,
        existing => "/etc/mail/mailer.conf",
        notify   => 1,
        clean    => 1,
    );
    close $MAILER_CONF;
};

sub config_write {
    my $self = shift;
    my $changes = shift;

    my $qdir    = $self->get_qmail_dir;
    my $control = "$qdir/control";
    $self->util->file_write( "$control/locals", lines => ["\n"] )
        if ! -e "$control/locals";

    foreach my $change (@$changes) {
        my $file  = $change->{'file'};
        my $value = $change->{'setting'};

        if ( -e "$qdir/$file" ) {
            my @now = $self->util->file_read( "$qdir/$file" );
            if ( @now && $now[0] && $now[0] eq $value ) {
                $self->audit( "config_write: $file to '$value', ok (same)" ) if $value !~ /pass/;
                next;
            };
        }
        else {
            $self->util->file_write( "$qdir/$file", lines => [$value] );
            $self->audit( "config: set $file to '$value'" ) if $value !~ /pass/;
            next;
        };

        $self->util->file_write( "$qdir/$file.tmp", lines => [$value] );

        my $r = $self->util->install_if_changed(
            newfile  => "$qdir/$file.tmp",
            existing => "$qdir/$file",
            clean    => 1,
            notify   => 1,
            verbose  => 0
        );
        if ($r) { $r = $r == 1 ? "ok" : "ok (same)"; }
        else    { $r = "FAILED"; }

        $self->audit( "config: setting $file to '$value', $r" ) if $value !~ /pass/;
    };

    my $manpath = "/etc/manpath.config";
    if ( -e $manpath ) {
        unless (`grep "$qdir/man" $manpath | grep -v grep`) {
            $self->util->file_write( $manpath,
                lines  => ["OPTIONAL_MANPATH\t\t$qdir/man"],
                append => 1,
            );
            $self->audit( "appended $qdir/man to MANPATH" );
        }
    }
};

sub control_sql {
    my $self = shift;
    my $conf = $self->conf;

    my $dbhost = $conf->{vpopmail_mysql_repl_slave}
            or die "missing db hostname\n";
    my $dbport = $conf->{vpopmail_mysql_repl_slave_port}
            or die "missing db server port\n";
    my $dbname = $conf->{vpopmail_mysql_database}
        or die "missing db name\n";
    my $dbuser = $conf->{vpopmail_mysql_user}
        or die "missing vpopmail SQL username\n";
    my $password = $conf->{vpopmail_mysql_pass}
        or die "missing vpopmail SQL pass\n";

    return {
        file => 'control/sql',
        setting => "server $dbhost
port $dbport
database $dbname
table relay
user $dbuser
pass $password
time 1800
",
    };
};

sub control_create {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $conf     = $self->conf;
    my $qmaildir = $self->get_qmail_dir;
    my $confdir  = $conf->{system_config_dir} || '/usr/local/etc';
    my $tmp      = $conf->{toaster_tmp_dir}   || '/tmp';
    my $prefix   = $conf->{toaster_prefix}    || '/usr/local';

    my $qmailctl = "$qmaildir/bin/qmailctl";

    return $p{test_ok} if defined $p{test_ok};

    # install a new qmailcontrol if newer than existing one.
    $self->control_write( "$tmp/qmailctl", %p );
    my $r = $self->util->install_if_changed(
        newfile  => "$tmp/qmailctl",
        existing => $qmailctl,
        mode     => '0755',
        notify   => 1,
        clean    => 1,
    );

    if ($r) { $r = $r == 1 ? 'ok' : "ok (same)"; } else { $r = "FAILED"; };

    $self->audit( "control_create: installed $qmaildir/bin/qmailctl, $r" );

    $self->util->syscmd( "$qmailctl cdb", verbose=>0 );

    # create aliases
    foreach my $shortcut ( "$prefix/sbin/qmail", "$prefix/sbin/qmailctl" ) {
        next if -l $shortcut;
        if ( -e $shortcut ) {
            $self->audit( "updating $shortcut.");
            unlink $shortcut;
            symlink( "$qmaildir/bin/qmailctl", $shortcut )
                or $self->error( "couldn't link $shortcut: $!");
        }
        else {
            $self->audit( "control_create: adding symlink $shortcut");
            symlink( "$qmaildir/bin/qmailctl", $shortcut )
                or $self->error( "couldn't link $shortcut: $!");
        }
    }

    if ( -e "$qmaildir/rc" ) {
        $self->audit( "control_create: $qmaildir/rc already exists.");
    }
    else {
        $self->build_send_run();
        my $dir = $self->toaster->supervise_dir_get( 'send' );
        copy( "$dir/run", "$qmaildir/rc" ) and
            $self->audit( "control_create: created $qmaildir/rc.");
        chmod oct('0755'), "$qmaildir/rc";
    }

    # the FreeBSD port used to install this
    if ( -e "$confdir/rc.d/qmail.sh" ) {
        unlink("$confdir/rc.d/qmail.sh")
          or $self->error( "couldn't delete $confdir/rc.d/qmail.sh: $!");
    }
}

sub control_write {
    my $self = shift;
    my $file = shift or die "missing file name";
    my %p = validate( @_, { $self->get_std_opts } );

    open ( my $FILE_HANDLE, '>', $file ) or
        return $self->error( "failed to open $file: $!" );

    my $qdir   = $self->get_qmail_dir;
    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local";
    my $tcprules = $self->util->find_bin( 'tcprules', %p );
    my $svc      = $self->util->find_bin( 'svc', %p );
    my $vpopetc = $self->setup->vpopmail->get_vpop_etc;

    print $FILE_HANDLE <<EOQMAILCTL;
#!/bin/sh

PATH=$qdir/bin:$prefix/bin:/usr/bin:/bin
export PATH

case "\$1" in
	stat)
		cd $qdir/supervise
		svstat * */log
	;;
	doqueue|alrm|flush)
		echo "Sending ALRM signal to qmail-send."
		$svc -a $qdir/supervise/send
	;;
	queue)
		qmail-qstat
		qmail-qread
	;;
	reload|hup)
		echo "Sending HUP signal to qmail-send."
		$svc -h $qdir/supervise/send
	;;
	pause)
		echo "Pausing qmail-send"
		$svc -p $qdir/supervise/send
		echo "Pausing qmail-smtpd"
		$svc -p $qdir/supervise/smtp
	;;
	cont)
		echo "Continuing qmail-send"
		$svc -c $qdir/supervise/send
		echo "Continuing qmail-smtpd"
		$svc -c $qdir/supervise/smtp
	;;
	restart)
		echo "Restarting qmail:"
		echo "* Stopping qmail-smtpd."
		$svc -d $qdir/supervise/smtp
		echo "* Sending qmail-send SIGTERM and restarting."
		$svc -t $qdir/supervise/send
		echo "* Restarting qmail-smtpd."
		$svc -u $qdir/supervise/smtp
	;;
	cdb)
		if [ -s $vpopetc/tcp.smtp ]
		then
			$tcprules $vpopetc/tcp.smtp.cdb $vpopetc/tcp.smtp.tmp < $vpopetc/tcp.smtp
			chmod 644 $vpopetc/tcp.smtp*
			echo "Reloaded $vpopetc/tcp.smtp."
		fi

		if [ -s $vpopetc/tcp.submit ]
		then
			$tcprules $vpopetc/tcp.submit.cdb $vpopetc/tcp.submit.tmp < $vpopetc/tcp.submit
			chmod 644 $vpopetc/tcp.submit*
			echo "Reloaded $vpopetc/tcp.submit."
		fi

		if [ -s /etc/tcp.smtp ]
		then
			$tcprules /etc/tcp.smtp.cdb /etc/tcp.smtp.tmp < /etc/tcp.smtp
			chmod 644 /etc/tcp.smtp*
			echo "Reloaded /etc/tcp.smtp."
		fi

		if [ -s $qdir/control/simcontrol ]
		then
			if [ -x $qdir/bin/simscanmk ]
			then
				$qdir/bin/simscanmk
				echo "Reloaded $qdir/control/simcontrol."
				$qdir/bin/simscanmk -g
				echo "Reloaded $qdir/control/simversions."
			fi
		fi

		if [ -s $qdir/users/assign ]
		then
			if [ -x $qdir/bin/qmail-newu ]
			then
				echo "Reloaded $qdir/users/assign."
			fi
		fi

		if [ -s $qdir/control/morercpthosts ]
		then
			if [ -x $qdir/bin/qmail-newmrh ]
			then
				$qdir/bin/qmail-newmrh
				echo "Reloaded $qdir/control/morercpthosts"
			fi
		fi

		if [ -s $qdir/control/spamt ]
		then
			if [ -x $qdir/bin/qmail-newst ]
			then
				$qdir/bin/qmail-newst
				echo "Reloaded $qdir/control/spamt"
			fi
		fi
	;;
	help)
		cat <<HELP
		pause -- temporarily stops mail service (connections accepted, nothing leaves)
		cont -- continues paused mail service
		stat -- displays status of mail service
		cdb -- rebuild the cdb files (tcp.smtp, users, simcontrol)
		restart -- stops and restarts smtp, sends qmail-send a TERM & restarts it
		doqueue -- sends qmail-send ALRM, scheduling queued messages for delivery
		reload -- sends qmail-send HUP, rereading locals and virtualdomains
		queue -- shows status of queue
		alrm -- same as doqueue
		hup -- same as reload
HELP
	;;
	*)
		echo "Usage: \$0 {restart|doqueue|flush|reload|stat|pause|cont|cdb|queue|help}"
		exit 1
	;;
esac

exit 0

EOQMAILCTL

    close $FILE_HANDLE;
}

sub get_domains_from_assign {
    my $self = shift;
    my %p = validate ( @_, {
            'match'   => { type=>SCALAR,  optional=>1, },
            'value'   => { type=>SCALAR,  optional=>1, },
            $self->get_std_opts,
        },
    );

    my %args = $self->get_std_args( %p );
    my ( $match, $value, $fatal, $verbose )
        = ( $p{match}, $p{value}, $p{fatal}, $p{verbose} );

    my $qdir  = $self->get_qmail_dir;
    my $assign = "$qdir/users/assign";

    return $p{test_ok} if defined $p{test_ok};

    return $self->error( "the file $assign is missing or empty!", %args )
        if ! -s $assign;

    my @domains;
    my @lines = $self->util->file_read( $assign );

    foreach my $line (@lines) {
        chomp $line;
        my @fields = split( /:/, $line );
        if ( $fields[0] ne "" && $fields[0] ne "." ) {
            my %domain = (
                stat => $fields[0],
                dom  => $fields[1],
                uid  => $fields[2],
                gid  => $fields[3],
                dir  => $fields[4],
            );

            if (! $match) { push @domains, \%domain; next; };

            if ( $match eq "dom" && $value eq "$fields[1]" ) {
                push @domains, \%domain;
            }
            elsif ( $match eq "uid" && $value eq "$fields[2]" ) {
                push @domains, \%domain;
            }
            elsif ( $match eq "dir" && $value eq "$fields[4]" ) {
                push @domains, \%domain;
            }
        }
    }
    return @domains;
}

sub get_list_of_rbls {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    # two arrays, one for sorted elements, one for unsorted
    my ( @sorted, @unsorted );
    my ( @list,   %sort_keys, $sort );

    foreach my $key ( keys %{$self->conf} ) {

        # ignore everything that doesn't start wih rbl
        next unless ( $key =~ /^rbl/ );

        # ignore other similar keys in $conf
        next if ( $key =~ /^rbl_enable/ );
        next if ( $key =~ /^rbl_reverse_dns/ );
        next if ( $key =~ /^rbl_timeout/ );
        next if ( $key =~ /_message$/ );        # RBL custom reject messages
        next if ( $self->conf->{$key} == 0 );         # not enabled

        $key =~ /^rbl_([a-zA-Z0-9\.\-]*)\s*$/;

        $self->audit( "good key: $1 ");

        # test for custom sort key
        if ( $self->conf->{$key} > 1 ) {
            $self->audit( "  sorted value ".$self->conf->{$key} );
            @sorted[ $self->conf->{$key} - 2 ] = $1;
        }
        else {
            $self->audit( "  unsorted, ".$self->conf->{$key} );
            push @unsorted, $1;
        }
    }

    # add the unsorted values to the sorted list
    push @sorted, @unsorted;
    @sorted = grep { defined $_ } @sorted;   # weed out blanks
    @sorted = grep { $_ =~ /\S/ } @sorted;

    $self->audit( "sorted order: " . join( "\n\t", @sorted ) );

    # test each RBL in the list
    my $good_rbls = $self->test_each_rbl( rbls => \@sorted ) or return q{};

    # format them for use in a supervised (daemontools) run file
    my $string_of_rbls;
    foreach (@$good_rbls) {
        my $mess = $self->conf->{"rbl_${_}_message"};
        $string_of_rbls .= " \\\n\t\t-r $_";
        if ( defined $mess && $mess ) {
            $string_of_rbls .= ":'$mess'";
        }
    }

    $self->audit( $string_of_rbls );
    return $string_of_rbls;
}

sub get_list_of_rwls {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my @list;

    foreach my $key ( keys %{$self->conf} ) {

        next unless ( $key =~ /^rwl/ && $self->conf->{$key} == 1 );
        next if ( $key =~ /^rwl_enable/ );

        $key =~ /^rwl_([a-zA-Z_\.\-]*)\s*$/;

        $self->audit( "good key: $1");
        push @list, $1;
    }
    return \@list;
}

sub get_qmailscanner_virus_sender_ips {

    # deprecated function

    my $self = shift;
    my @ips;

    my $verbose      = $self->conf->{verbose};
    my $block      = $self->conf->{qs_block_virus_senders};
    my $clean      = $self->conf->{qs_quarantine_clean};
    my $quarantine = $self->conf->{qs_quarantine_dir};

    if (! -d $quarantine ) {
        $quarantine = "/var/spool/qmailscan/quarantine"
          if -d "/var/spool/qmailscan/quarantine";
    }

    return $self->error( "no quarantine dir!") if ! -d "$quarantine/new";
    my @files = $self->util->get_dir_files( "$quarantine/new" );

    foreach my $file (@files) {
        if ($block) {
            my $ipline = `head -n 10 $file | grep HELO`;
            chomp $ipline;

            next unless ($ipline);
            print " $ipline  - " if $verbose;

            my @lines = split( /Received/, $ipline );
            foreach my $line (@lines) {
                print $line if $verbose;

                # Received: from unknown (HELO netbible.org) (202.54.63.141)
                my ($ip) = $line =~ /([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/;

                # check the message and verify that it's
                # a blocked virus, not an admin testing
                # (Matt 4/3/2004)

                if ( $ip =~ /\s+/ or !$ip ) { print "$line\n" if $verbose; }
                else { push @ips, $ip; }
                print "\t$ip" if $verbose;
            }
            print "\n" if $verbose;
        }
        unlink $file if $clean;
    }

    my ( %hash, @sorted );
    foreach (@ips) { $hash{$_} = "1"; }
    foreach ( keys %hash ) { push @sorted, $_; delete $hash{$_} }
    $self->audit( "found " . scalar @sorted . " infected files" ) if scalar @sorted;
    return @sorted;
}

sub get_supervise_dir {
    my $self = shift;
    my $dir = $self->conf->{qmail_supervise} || $self->get_qmail_dir . '/supervise';
    if ( ! -d $dir ) {
        $self->util->mkdir_system( dir => $dir, fatal => 0 );
    };
    return $dir if -d $dir;
    $self->error( "$dir does not exist!",fatal=>0);
    return $dir;
};

sub get_qmail_dir {
    my $self = shift;
    return $self->conf->{'qmail_dir'} || '/var/qmail';
};

sub get_control_dir {
    my $self = shift;
    my $qmail_dir  = $self->get_qmail_dir;
    return "$qmail_dir/control";
};

sub install_qmail {
    my $self = shift;
    my %p = validate( @_, {
            'package' => { type=>SCALAR,  optional=>1, },
            $self->get_std_opts,
        },
    );

    my $package = $p{'package'};

    my ( $patch, $chkusr );

    return $p{'test_ok'} if defined $p{'test_ok'};

    # redirect if netqmail is selected
    if ( $self->conf->{'install_netqmail'} ) {
        return $self->netqmail();
    }

    my $ver = $self->conf->{'install_qmail'} or do {
        print "install_qmail: installation disabled in .conf, SKIPPING";
        return;
    };

    $self->install_qmail_groups_users();

    $package ||= "qmail-$ver";

    my $src      = $self->conf->{'toaster_src_dir'}   || "/usr/local/src";
    my $qmaildir = $self->get_qmail_dir;
    my $vpopdir  = $self->setup->vpopmail->get_vpop_dir;
    my $mysql = $self->conf->{'qmail_mysql_include'}
      || "/usr/local/lib/mysql/libmysqlclient.a";
    my $dl_site = $self->conf->{'toaster_dl_site'} || "http://www.tnpi.net";
    my $dl_url  = $self->conf->{'toaster_dl_url'}  || "/internet/mail/toaster";
    my $toaster_url = "$dl_site$dl_url";

    $self->util->cwd_source_dir( "$src/mail" );

    if ( -e $package ) {
        unless ( $self->util->source_warning( package=>$package, src=>$src ) ) {
            warn "install_qmail: FATAL: sorry, I can't continue.\n";
            return;
        }
    }

    unless ( defined $self->conf->{'qmail_chk_usr_patch'} ) {
        print "\nCheckUser support causes the qmail-smtpd daemon to verify that
a user exists locally before accepting the message, during the SMTP conversation.
This prevents your mail server from accepting messages to email addresses that
don't exist in vpopmail. It is not compatible with system user mailboxes. \n\n";

        $chkusr =
          $self->util->yes_or_no( "Do you want qmail-smtpd-chkusr support enabled?" );
    }
    else {
        if ( $self->conf->{'qmail_chk_usr_patch'} ) {
            $chkusr = 1;
            print "chk-usr patch: yes\n";
        }
    }

    if ($chkusr) { $patch = "$package-toaster-2.8.patch"; }
    else { $patch = "$package-toaster-2.6.patch"; }

    my $site = "http://cr.yp.to/software";

    unless ( -e "$package.tar.gz" ) {
        if ( -e "/usr/ports/distfiles/$package.tar.gz" ) {
            use File::Copy;
            copy( "/usr/ports/distfiles/$package.tar.gz",
                "$src/mail/$package.tar.gz" );
        }
        else {
            $self->util->get_url( "$site/$package.tar.gz" );
            unless ( -e "$package.tar.gz" ) {
                die "install_qmail FAILED: couldn't fetch $package.tar.gz!\n";
            }
        }
    }

    unless ( -e $patch ) {
        $self->util->get_url( "$toaster_url/patches/$patch" );
        unless ( -e $patch ) { die "\n\nfailed to fetch patch $patch!\n\n"; }
    }

    my $tar      = $self->util->find_bin( "tar"  );
    my $patchbin = $self->util->find_bin( "patch" );
    unless ( $tar && $patchbin ) { die "couldn't find tar or patch!\n"; }

    $self->util->syscmd( "$tar -xzf $package.tar.gz" );
    chdir("$src/mail/$package")
      or die "install_qmail: cd $src/mail/$package failed: $!\n";
    $self->util->syscmd( "$patchbin < $src/mail/$patch" );

    $self->util->file_write( "conf-qmail", lines => [$qmaildir] )
      or die "couldn't write to conf-qmail: $!";

    $self->util->file_write( "conf-vpopmail", lines => [$vpopdir] )
      or die "couldn't write to conf-vpopmail: $!";

    $self->util->file_write( "conf-mysql", lines => [$mysql] )
      or die "couldn't write to conf-mysql: $!";

    my $servicectl = "/usr/local/sbin/services";

    if ( -x $servicectl ) {

        print "Stopping Qmail!\n";
        $self->util->syscmd( "$servicectl stop" );
        $self->send_stop();
    }

    my $make = $self->util->find_bin( "gmake", fatal => 0 );
    $make  ||= $self->util->find_bin( "make" );

    $self->util->syscmd( "$make setup" );

    unless ( -f "$qmaildir/control/servercert.pem" ) {
        $self->util->syscmd( "$make cert" );
    }

    if ($chkusr) {
        $self->util->chown( "$qmaildir/bin/qmail-smtpd",
            uid => 'vpopmail',
            gid => 'vchkpw',
        );

        $self->util->chmod( file => "$qmaildir/bin/qmail-smtpd",
            mode  => '6555',
        );
    }

    unless ( -e "/usr/share/skel/Maildir" ) {

# deprecated, not necessary unless using system accounts
# $self->util->syscmd( "$qmaildir/bin/maildirmake /usr/share/skel/Maildir" );
    }

    $self->config();

    if ( -x $servicectl ) {
        print "Starting Qmail & supervised services!\n";
        $self->util->syscmd( "$servicectl start" );
    }
}

sub install_qmail_control_files {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $supervise = $self->get_supervise_dir;

    return $p{'test_ok'} if defined $p{'test_ok'};

    foreach my $prot ( $self->toaster->get_daemons(1) ) {
        my $supdir = $self->toaster->supervise_dir_get( $prot);
        my $run_f = "$supdir/run";

        if ( -e $run_f ) {
            $self->audit( "install_qmail_control_files: $run_f already exists!");
            next;
        }

        if    ( $prot eq "smtp"   ) { $self->build_smtp_run   }
        elsif ( $prot eq "send"   ) { $self->build_send_run   }
        elsif ( $prot eq "pop3"   ) { $self->build_pop3_run   }
        elsif ( $prot eq "submit" ) { $self->build_submit_run }
        elsif ( $prot eq "qmail-deliverable" ) { $self->build_qmail_deliverable_run }
        elsif ( $prot eq "vpopmaild" ) { $self->build_vpopmaild_run }
        elsif ( $prot eq "qpsmtpd" ) { $self->build_qpsmtpd_run }
        else  { $self->error("I need help making run for $prot!"); };
    }
}

sub install_qmail_groups_users {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $err = "ERROR: You need to update your toaster-watcher.conf file!\n";

    my $qmailg   = $self->conf->{'qmail_group'}       || 'qmail';
    my $alias    = $self->conf->{'qmail_user_alias'}  || 'alias';
    my $qmaild   = $self->conf->{'qmail_user_daemon'} || 'qmaild';
    my $qmailp   = $self->conf->{'qmail_user_passwd'} || 'qmailp';
    my $qmailq   = $self->conf->{'qmail_user_queue'}  || 'qmailq';
    my $qmailr   = $self->conf->{'qmail_user_remote'} || 'qmailr';
    my $qmails   = $self->conf->{'qmail_user_send'}   || 'qmails';
    my $qmaill   = $self->conf->{'qmail_user_log'}    || 'qmaill';
    my $nofiles  = $self->conf->{'qmail_log_group'}   || 'nofiles';

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $uid = 81;
    my $gid = 81;

    if ( $OSNAME eq 'darwin' ) { $uid = $gid = 200; }

    $self->setup->group_add( 'qnofiles', $gid );
    $self->setup->group_add( $qmailg, $gid + 1 );

    my $homedir = $self->get_qmail_dir;

    $self->setup->user_add($alias, $uid, $gid, homedir => "$homedir/alias" );
    $uid++;
    $self->setup->user_add($qmaild, $uid, $gid, homedir => $homedir );
    $uid++;
    $self->setup->user_add($qmaill, $uid, $gid, homedir => $homedir );
    $uid++;
    $self->setup->user_add($qmailp, $uid, $gid, homedir => $homedir );
    $uid++;
    $gid++;
    $self->setup->user_add($qmailq, $uid, $gid, homedir => $homedir );
    $uid++;
    $self->setup->user_add($qmailr, $uid, $gid, homedir => $homedir );
    $uid++;
    $self->setup->user_add($qmails, $uid, $gid, homedir => $homedir );
}

sub install_supervise_run {
    my $self = shift;
    my %p = validate( @_, {
            'tmpfile'     => { type=>SCALAR,  },
            'destination' => { type=>SCALAR,  optional=>1, },
            'prot'        => { type=>SCALAR,  optional=>1, },
            $self->get_std_opts,
        },
    );
    my %args = $self->toaster->get_std_args( %p );

    return $p{test_ok} if defined $p{test_ok};

    my ( $tmpfile, $destination, $prot )
        = ( $p{tmpfile}, $p{destination}, $p{prot} );

    if ( !$destination ) {
        return $self->error( "you didn't set destination or prot!", %args ) if !$prot;

        my $dir = $self->toaster->supervise_dir_get( $prot )
            or return $self->error( "no sup dir for $prot found", %args );
        $destination = "$dir/run";
    }

    return $self->error( "the new file ($tmpfile) is missing!",%args)
        if !-e $tmpfile;

    my $s = -e $destination ? 'updating' : 'installing';
    $self->audit( "install_supervise_run: $s $destination");

    return $self->util->install_if_changed(
        existing => $destination,  newfile  => $tmpfile,
        mode     => '0755',        clean    => 1,
        notify   => $self->conf->{supervise_rebuild_notice} || 1,
        email    => $self->conf->{toaster_admin_email} || 'postmaster',
        %args,
    );
}

sub install_qmail_control_log_files {
    my $self = shift;
    my %p = validate( @_, {
            prots   => {
                type=>ARRAYREF, optional=>1,
                default=>['smtp', 'send', 'pop3', 'submit'],
            },
            $self->get_std_opts,
        },
    );

    my %args = $self->toaster->get_std_args( %p );
    my $prots = $p{prots};
    push @$prots, "vpopmaild" if $self->conf->{vpopmail_daemon};

    my $supervise = $self->get_supervise_dir;

    my %valid_prots = map { $_ => 1 } qw/ smtp send pop3 submit vpopmaild /;

    return $p{test_ok} if defined $p{test_ok};

    # Create log/run files
    foreach my $serv (@$prots) {

        die "invalid protocol: $serv!\n" unless $valid_prots{$serv};

        my $supervisedir = $self->toaster->supervise_dir_get( $serv );
        my $run_f = "$supervisedir/log/run";

        $self->audit( "install_qmail_control_log_files: preparing $run_f");

        my @lines = $self->toaster->supervised_do_not_edit_notice;
        push @lines, $self->toaster->supervised_multilog($serv);

        my $tmpfile = "/tmp/mt_supervise_" . $serv . "_log_run";
        $self->util->file_write( $tmpfile, lines => \@lines );

        $self->audit( "install_qmail_control_log_files: comparing $run_f");

        my $notify = $self->conf->{'supervise_rebuild_notice'} ? 1 : 0;

        if ( -s $tmpfile ) {
            $self->util->install_if_changed(
                newfile  => $tmpfile, existing => $run_f,
                mode     => '0755',   clean    => 1,
                notify   => $notify,  email    => $self->conf->{'toaster_admin_email'},
            ) or return;
            $self->audit( " updating $run_f, ok" );
        }

        $self->toaster->supervised_dir_test( $serv );
    }
}

sub install_ssl_temp_key {
    my ( $self, $cert, $fatal ) = @_;

    my $user  = $self->conf->{'smtpd_run_as_user'} || "vpopmail";
    my $group = $self->conf->{'qmail_group'}       || "qmail";

    $self->util->chmod(
        file_or_dir => "$cert.new",
        mode        => '0660',
        fatal       => $fatal,
    );

    $self->util->chown( "$cert.new",
        uid   => $user,
        gid   => $group,
        fatal => $fatal,
    );

    move( "$cert.new", $cert );
}

sub maildir_in_skel {

    my $skel = "/usr/share/skel";
    if ( ! -d $skel ) {
        $skel = "/etc/skel" if -d "/etc/skel";    # linux
    }

    if ( ! -e "$skel/Maildir" ) {
        # only necessary for systems with local email accounts
        #$self->util->syscmd( "$qmaildir/bin/maildirmake $skel/Maildir" ) ;
    }
}

sub netqmail {
    my $self = shift;
    my %p = validate( @_, {
            'package' => { type=>SCALAR,  optional=>1, },
            $self->get_std_opts,
        },
    );

    my $package = $p{package};
    my $ver     = $self->conf->{'install_netqmail'} || "1.05";
    my $src     = $self->conf->{'toaster_src_dir'}  || "/usr/local/src";
    my $vhome   = $self->setup->vpopmail->get_vpop_dir;

    $package ||= "netqmail-$ver";

    return $p{test_ok} if defined $p{test_ok};

    $self->install_qmail_groups_users();

    # check to see if qmail-smtpd already has vpopmail support
    return 0 if ! $self->netqmail_rebuild;

    $self->util->cwd_source_dir( "$src/mail" );

    $self->netqmail_get_sources( $package ) or return;
    my @patches = $self->netqmail_get_patches( $package );

    $self->util->extract_archive( "$package.tar.gz" );

    # netqmail requires a "collate" step before it can be built
    chdir("$src/mail/$package")
        or die "netqmail: cd $src/mail/$package failed: $!\n";

    $self->util->syscmd( "./collate.sh" );

    chdir("$src/mail/$package/$package")
        or die "netqmail: cd $src/mail/$package/$package failed: $!\n";

    my $patchbin = $self->util->find_bin( 'patch' );

    foreach my $patch (@patches) {
        print "\nnetqmail: applying patch $patch\n";
        sleep 1;
        $self->util->syscmd( "$patchbin < $src/mail/$patch" );
    };

    $self->netqmail_makefile_fixups();
    $self->netqmail_queue_extra()   if $self->conf->{'qmail_queue_extra'};
    $self->netqmail_darwin_fixups() if $OSNAME eq "darwin";
    $self->netqmail_conf_cc();
    $self->netqmail_conf_fixups();
    $self->netqmail_chkuser_fixups();

    my $servicectl = '/usr/local/sbin/services';
    $servicectl = '/usr/local/bin/services' if ! -x $servicectl;
    if ( -x $servicectl ) {
        print "Stopping Qmail!\n";
        $self->send_stop();
        system "$servicectl stop";
    }

    my $make = $self->util->find_bin( "gmake", fatal => 0 ) || $self->util->find_bin( "make" );
    $self->util->syscmd( "$make setup" );

    $self->netqmail_ssl( $make );
    $self->netqmail_permissions();

    $self->maildir_in_skel();
    $self->config();

    if ( -x $servicectl ) {
        print "Starting Qmail & supervised services!\n";
        system "$servicectl start";
    }
}

sub netqmail_chkuser_fixups {
    my $self = shift;

    return if ! $self->conf->{vpopmail_qmail_ext};

    my $file = 'chkuser_settings.h';
    print "netqmail: fixing up $file\n";

    my @lines = $self->util->file_read( $file );
    foreach my $line (@lines) {
        if ( $line =~ /^\/\* \#define CHKUSER_ENABLE_USERS_EXTENSIONS/ ) {
            $line = "#define CHKUSER_ENABLE_USERS_EXTENSIONS";
        }
    }
    $self->util->file_write( $file, lines => \@lines );

};

sub netqmail_conf_cc {
    my $self = shift;

    my $vpopdir    = $self->setup->vpopmail->get_vpop_dir;
    my $domainkeys = $self->conf->{'qmail_domainkeys'};

    # make changes to conf-cc
    print "netqmail: fixing up conf-cc\n";
    my $cmd = "cc -O2 -DTLS=20060104 -I$vpopdir/include";

    # add in the -I (include) dir for OpenSSL headers
    if ( -d "/opt/local/include/openssl" ) {
        print "netqmail: building against /opt/local/include/openssl.\n";
        $cmd .= " -I/opt/local/include/openssl";
    }
    elsif ( -d "/usr/local/include/openssl" && $self->conf->{'install_openssl'} )
    {
        print
          "netqmail: building against /usr/local/include/openssl from ports.\n";
        $cmd .= " -I/usr/local/include/openssl";
    }
    elsif ( -d "/usr/include/openssl" ) {
        print "netqmail: using system supplied OpenSSL libraries.\n";
        $cmd .= " -I/usr/include/openssl";
    }
    else {
        if ( -d "/usr/local/include/openssl" ) {
            print "netqmail: building against /usr/local/include/openssl.\n";
            $cmd .= " -I/usr/local/include/openssl";
        }
        else {
            print
"netqmail: WARNING: I couldn't find your OpenSSL libraries. This might cause problems!\n";
        }
    }

    # add in the include directory for libdomainkeys
    if ( $domainkeys ) {
        # make sure libdomainkeys is installed
        if ( ! -e "/usr/local/include/domainkeys.h" ) {
            $self->setup->domainkeys();
        };
        if ( -e "/usr/local/include/domainkeys.h" ) {
            $cmd .= " -I/usr/local/include";
        };
    };

    $self->util->file_write( "conf-cc", lines => [$cmd] );
};

sub netqmail_conf_fixups {
    my $self = shift;

    print "netqmail: fixing up conf-qmail\n";
    my $qmaildir = $self->get_qmail_dir;
    $self->util->file_write( "conf-qmail", lines => [$qmaildir] );

    print "netqmail: fixing up conf-vpopmail\n";
    my $vpopdir = $self->setup->vpopmail->get_vpop_dir;
    $self->util->file_write( "conf-vpopmail", lines => [$vpopdir] );

    print "netqmail: fixing up conf-mysql\n";
    my $mysql = $self->conf->{'qmail_mysql_include'} || "/usr/local/lib/mysql/libmysqlclient.a";
    $self->util->file_write( "conf-mysql", lines => [$mysql] );

    print "netqmail: fixing up conf-groups\n";
    my $q_group = $self->conf->{'qmail_group'} || 'qmail';
    my $l_group = $self->conf->{'qmail_log_group'} || "qnofiles";
    $self->util->file_write( "conf-groups", lines => [ $q_group, $l_group ] );
};

sub netqmail_darwin_fixups {
    my $self = shift;

    print "netqmail: fixing up conf-ld\n";
    $self->util->file_write( "conf-ld", lines => ["cc -Xlinker -x"] )
      or die "couldn't write to conf-ld: $!";

    print "netqmail: fixing up dns.c for Darwin\n";
    my @lines = $self->util->file_read( "dns.c" );
    foreach my $line (@lines) {
        if ( $line =~ /#include <netinet\/in.h>/ ) {
            $line = "#include <netinet/in.h>\n#include <nameser8_compat.h>";
        }
    }
    $self->util->file_write( "dns.c", lines => \@lines );

    print "netqmail: fixing up strerr_sys.c for Darwin\n";
    @lines = $self->util->file_read( "strerr_sys.c" );
    foreach my $line (@lines) {
        if ( $line =~ /struct strerr strerr_sys/ ) {
            $line = "struct strerr strerr_sys = {0,0,0,0};";
        }
    }
    $self->util->file_write( "strerr_sys.c", lines => \@lines );

    print "netqmail: fixing up hier.c for Darwin\n";
    @lines = $self->util->file_read( "hier.c" );
    foreach my $line (@lines) {
        if ( $line =~
            /c\(auto_qmail,"doc","INSTALL",auto_uido,auto_gidq,0644\)/ )
        {
            $line =
              'c(auto_qmail,"doc","INSTALL.txt",auto_uido,auto_gidq,0644);';
        }
    }
    $self->util->file_write( "hier.c", lines => \@lines );

    # fixes due to case sensitive file system
    move( "INSTALL",  "INSTALL.txt" );
    move( "SENDMAIL", "SENDMAIL.txt" );
}

sub netqmail_get_sources {
    my $self = shift;
    my $package = shift or croak "missing package name!";
    my $site = "http://www.qmail.org";
    my $src  = $self->conf->{'toaster_src_dir'}  || "/usr/local/src";

    $self->util->source_warning( package=>$package, src=>"$src/mail" ) or return;

    return 1 if -e "$package.tar.gz";   # already exists

    # check if the distfile is in the ports repo
    my $dist = "/usr/ports/distfiles/$package.tar.gz";
    if ( -e $dist ) {
        copy( $dist, "$src/mail/$package.tar.gz" );
    }
    return 1 if -e "$package.tar.gz";

    $self->util->get_url( "$site/$package.tar.gz" );
    return 1 if -e "$package.tar.gz";

    return $self->error( "couldn't fetch $package.tar.gz!" );
};

sub netqmail_get_patches {
    my $self = shift;
    my $package = shift;

    my $patch_ver = $self->conf->{'qmail_toaster_patch_version'};

    my @patches;
    push @patches, "$package-toaster-$patch_ver.patch" if $patch_ver;

    if ( defined $self->conf->{qmail_smtp_reject_patch} && $self->conf->{qmail_smtp_reject_patch} ) {
        push @patches, "$package-smtp_reject-3.0.patch";
    }

    if ( defined $self->conf->{qmail_domainkeys} && $self->conf->{qmail_domainkeys} ) {
        push @patches, "$package-toaster-3.1-dk.patch";
    };

    my ($sysname, undef, $version) = POSIX::uname;
    if ( $sysname eq 'FreeBSD' && $version =~ /^(9|10|11)/ )  {
        push @patches, "qmail-extra-patch-utmpx.patch";
    }

    my $dl_site    = $self->conf->{'toaster_dl_site'}   || "http://www.tnpi.net";
    my $dl_url     = $self->conf->{'toaster_dl_url'}    || "/internet/mail/toaster";
    my $toaster_url = "$dl_site$dl_url";

    foreach my $patch (@patches) {
        next if -e $patch;
        $self->util->get_url( "$toaster_url/patches/$patch" );
        next if -e $patch;
        return $self->error( "failed to fetch patch $patch!" );
    }
    return @patches;
};

sub netqmail_makefile_fixups {
    my $self = shift;
    my $vpopdir = $self->setup->vpopmail->get_vpop_dir;

    # find the openssl libraries
    my $prefix = $self->conf->{'toaster_prefix'} || "/usr/local/";
    my $ssl_lib = "$prefix/lib";
    if ( !-e "$ssl_lib/libcrypto.a" ) {
        if    ( -e "/opt/local/lib/libcrypto.a" ) { $ssl_lib = "/opt/local/lib"; }
        elsif ( -e "/usr/local/lib/libcrypto.a" ) { $ssl_lib = "/usr/local/lib"; }
        elsif ( -e "/opt/lib/libcrypto.a"       ) { $ssl_lib = "/opt/lib"; }
        elsif ( -e "/usr/lib/libcrypto.a"       ) { $ssl_lib = "/usr/lib"; }
    }


    my @lines = $self->util->file_read( "Makefile" );
    foreach my $line (@lines) {
        if ( $vpopdir ne "/home/vpopmail" ) {    # fix up vpopmail home dir
            if ( $line =~ /^VPOPMAIL_HOME/ ) {
                $line = 'VPOPMAIL_HOME=' . $vpopdir;
            }
        }

        # add in the discovered ssl library location
        if ( $line =~
            /tls.o ssl_timeoutio.o -L\/usr\/local\/ssl\/lib -lssl -lcrypto/ )
        {
            $line =
              '	tls.o ssl_timeoutio.o -L' . $ssl_lib . ' -lssl -lcrypto \\';
        }

        # again with the ssl libs
        if ( $line =~
/constmap.o tls.o ssl_timeoutio.o ndelay.a -L\/usr\/local\/ssl\/lib -lssl -lcrypto \\/
          )
        {
            $line =
                '	constmap.o tls.o ssl_timeoutio.o ndelay.a -L' . $ssl_lib
              . ' -lssl -lcrypto \\';
        }
    }
    $self->util->file_write( "Makefile", lines => \@lines );
};

sub netqmail_permissions {
    my $self = shift;

    my $qmaildir = $self->get_qmail_dir;
    $self->util->chown( "$qmaildir/bin/qmail-smtpd",
        uid  => 'vpopmail',
        gid  => 'vchkpw',
    );

    $self->util->chmod(
        file_or_dir => "$qmaildir/bin/qmail-smtpd",
        mode        => '6555',
    );
};

sub netqmail_queue_extra {
    my $self = shift;

    print "netqmail: enabling QUEUE_EXTRA...\n";
    my $success = 0;
    my @lines = $self->util->file_read( "extra.h" );
    foreach my $line (@lines) {
        if ( $line =~ /#define QUEUE_EXTRA ""/ ) {
            $line = '#define QUEUE_EXTRA "Tlog\0"';
            $success++;
        }

        if ( $line =~ /#define QUEUE_EXTRALEN 0/ ) {
            $line = '#define QUEUE_EXTRALEN 5';
            $success++;
        }
    }

    if ( $success == 2 ) {
        print "success.\n";
        $self->util->file_write( "extra.h", lines => \@lines );
    }
    else {
        print "FAILED.\n";
    }
}

sub netqmail_rebuild {
    my $self = shift;

    my $qdir = $self->get_qmail_dir;

    return 1 if ! -x "$qdir/bin/qmail-smtpd";    # not yet installed

    # does not have vpopmail support
    return 1 if ! `strings $qdir/bin/qmail-smtpd | grep vpopmail`;

    return $self->util->yes_or_no(
                "toasterized qmail is already installed, do you want to reinstall",
                timeout => 30,
            );
}

sub netqmail_ssl {
    my $self = shift;
    my $make = shift;

    my $qmaildir = $self->get_qmail_dir;

    if ( ! -d "$qmaildir/control" ) {
        mkpath "$qmaildir/control";
    };

    $ENV{PATH} = "/bin:/sbin:/usr/bin:/usr/sbin";
    if ( ! -f "$qmaildir/control/servercert.pem" ) {
        print "netqmail: installing SSL certificate\n";
        if ( -f "/usr/local/openssl/certs/server.pem" ) {
            copy( "/usr/local/openssl/certs/server.pem", "$qmaildir/control/servercert.pem");
            link( "$qmaildir/control/servercert.pem", "$qmaildir/control/clientcert.pem" );
        }
        else {
            system "$make cert";
        };
    }

    if ( ! -f "$qmaildir/control/rsa512.pem" ) {
        print "netqmail: install temp SSL \n";
        system "$make tmprsadh";
    }
};

sub netqmail_virgin {
    my $self = shift;
    my %p = validate( @_, {
            'package' => { type=>SCALAR,  optional=>1, },
            $self->get_std_opts,
        },
    );

    my $package = $p{'package'};
    my $chkusr;

    my $ver      = $self->conf->{'install_netqmail'} || "1.05";
    my $src      = $self->conf->{'toaster_src_dir'}  || "/usr/local/src";
    my $qmaildir = $self->get_qmail_dir;

    $package ||= "netqmail-$ver";

    my $mysql = $self->conf->{'qmail_mysql_include'}
      || "/usr/local/lib/mysql/libmysqlclient.a";
    my $qmailgroup = $self->conf->{'qmail_log_group'} || "qnofiles";

    # we do not want to try installing anything during "make test"
    if ( defined $p{'test_ok'} ) { return $p{'test_ok'}; }

    $self->install_qmail_groups_users();

    $self->util->cwd_source_dir( "$src/mail" );
    $self->netqmail_get_sources( $package );

    unless ( $self->util->extract_archive( "$package.tar.gz" ) ) {
        die "couldn't expand $package.tar.gz\n";
    }

    # netqmail requires a "collate" step before it can be built
    chdir("$src/mail/$package")
      or die "netqmail: cd $src/mail/$package failed: $!\n";
    $self->util->syscmd( "./collate.sh" );
    chdir("$src/mail/$package/$package")
      or die "netqmail: cd $src/mail/$package/$package failed: $!\n";

    $self->netqmail_conf_fixups();
    $self->netqmail_darwin_fixups() if $OSNAME eq 'darwin';

    print "netqmail: fixing up conf-cc\n";
    $self->util->file_write( "conf-cc", lines => ["cc -O2"] )
      or die "couldn't write to conf-cc: $!";

    my $servicectl = "/usr/local/sbin/services";
    if ( -x $servicectl ) {
        print "Stopping Qmail!\n";
        $self->send_stop();
        $self->util->syscmd( "$servicectl stop" );
    }

    my $make = $self->util->find_bin( "gmake", fatal => 0 ) || $self->util->find_bin( "make" );
    $self->util->syscmd( "$make setup" );

    $self->maildir_in_skel();
    $self->config();

    if ( -x $servicectl ) {
        print "Starting Qmail & supervised services!\n";
        $self->util->syscmd( "$servicectl start" );
    }
}

sub queue_check {
    # used in qqtool.pl

    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $base  = $self->conf->{qmail_dir};
    unless ( $base ) {
        print "queue_check: ERROR! qmail_dir is not set in conf! This is almost certainly an error!\n";
        $base = "/var/qmail"
    }

    my $queue = "$base/queue";

    unless ( $queue && -d $queue ) {
        my $err = "\tHEY! The queue directory for qmail is missing!\n";
        $err .= "\tI expected it to be at $queue\n" if $queue;
        $err .= "\tIt should have been set via the qmail_dir setting in toaster-watcher.conf!\n";

        return $self->error( $err, fatal => $p{fatal} );
    }

    $self->audit( "queue_check: checking $queue...ok" );
    return "$base/queue";
}

sub rebuild_simscan_control {
    my $self = shift;
    return if ! $self->conf->{install_simscan};

    my $qmdir = $self->get_qmail_dir;

    my $control = "$qmdir/control/simcontrol";
    return if ! -f $control;
    return 1 if ( -e "$control.cdb" && ! $self->util->file_is_newer( f1=>$control, f2=>"$control.cdb" ) );

    my $simscanmk = "$qmdir/bin/simscanmk";
    return if ! -x $simscanmk;

    `$simscanmk` or return 1;
    `$simscanmk -g`;    # for old versions of simscan
};

sub rebuild_ssl_temp_keys {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $openssl = $self->util->find_bin( "openssl" );
    my $fatal = $p{fatal};

    my $qmdir = $self->get_qmail_dir;
    my $cert  = "$qmdir/control/rsa512.pem";

    return $p{'test_ok'} if defined $p{'test_ok'};

    if ( ! -f $cert || -M $cert >= 1 || !-e $cert ) {
        $self->audit( "rebuild_ssl_temp_keys: rebuilding RSA key");
        $self->util->syscmd( "$openssl genrsa -out $cert.new 512 2>/dev/null" );

        $self->install_ssl_temp_key( $cert, $fatal );
    }

    $cert = "$qmdir/control/dh512.pem";
    if ( ! -f $cert || -M $cert >= 1 || !-e $cert ) {
        $self->audit( "rebuild_ssl_temp_keys: rebuilding DSA 512 key");
        $self->util->syscmd( "$openssl dhparam -2 -out $cert.new 512 2>/dev/null" );

        $self->install_ssl_temp_key( $cert, $fatal );
    }

    $cert = "$qmdir/control/dh1024.pem";
    if ( ! -f $cert || -M $cert >= 1 || !-e $cert ) {
        $self->audit( "rebuild_ssl_temp_keys: rebuilding DSA 1024 key");
        system  "$openssl dhparam -2 -out $cert.new 1024 2>/dev/null";
        $self->install_ssl_temp_key( $cert, $fatal );
    }

    return 1;
}

sub restart {
    my $self = shift;
    my %p = validate( @_, { 'prot' => { type => SCALAR }, $self->get_std_opts } );

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $prot = $p{'prot'};
    my $dir = $self->toaster->service_dir_get( $prot ) or return;

    return $self->error( "no such dir: $dir!", fatal=>0 ) unless ( -d $dir || -l $dir );

    $self->toaster->supervise_restart($dir);
}

sub send_start {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $qcontrol = $self->toaster->service_dir_get( "send" );

    return $p{'test_ok'}  if defined $p{'test_ok'};

    return $self->error( "uh oh, the service directory $qcontrol is missing!") if ! -d $qcontrol;

    if ( ! $self->toaster->supervised_dir_test( "send" ) ) {
        return $self->error( "something is wrong with the service/send dir." );
    }

    return $self->error( "Only root can control supervised daemons, and you aren't root!") if $UID != 0;

    my $svc    = $self->util->find_bin( "svc", verbose=>0 );
    my $svstat = $self->util->find_bin( "svstat", verbose=>0 );

    # Start the qmail-send (and related programs)
    system "$svc -u $qcontrol";

    # loop until it is up and running.
    foreach my $i ( 1 .. 200 ) {
        my $r = `$svstat $qcontrol`;
        chomp $r;
        if ( $r =~ /^.*:\sup\s\(pid [0-9]*\)\s[0-9]*\sseconds$/ ) {
            print "Yay, we're up!\n";
            return 1;
        }
        sleep 1;
    }
    return 1;
}

sub send_stop {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my %args = ( verbose => $p{verbose}, fatal => $p{fatal} );

    return $p{'test_ok'} if defined $p{'test_ok'};

    my $svc    = $self->util->find_bin( "svc", verbose=>0 );
    my $svstat = $self->util->find_bin( "svstat", verbose=>0 );

    my $qcontrol = $self->toaster->service_dir_get( "send" );

    return $self->error( "uh oh, the service directory $qcontrol is missing! Giving up.",
        %args ) unless $qcontrol;

    return $self->error( "something was wrong with the service/send dir." )
        if ! $self->toaster->supervised_dir_test( "send" );

    return $self->error( "Only root can control supervised daemons, and you aren't root!",
        %args ) if $UID != 0;

    # send qmail-send a TERM signal
    system "$svc -d $qcontrol";

    # loop up to a thousand seconds waiting for qmail-send to exit
    foreach my $i ( 1 .. 1000 ) {
        my $r = `$svstat $qcontrol`;
        chomp $r;
        if ( $r =~ /^.*:\sdown\s[0-9]*\sseconds/ ) {
            print "Yay, we're down!\n";
            return;
        }
        elsif ( $r =~ /supervise not running/ ) {
            print "Yay, we're down!\n";
            return;
        }
        else {

            # if more than 100 seconds passes, lets kill off the qmail-remote
            # processes that are forcing us to wait.

            if ( $i > 100 ) {
                $self->util->syscmd( "killall qmail-remote", verbose=>0 );
            }
            print "$r\n";
        }
        sleep 1;
    }
    return 1;
}

sub smtp_get_simenv {
    my $self = shift;

    if ( $self->conf->{'simscan_debug'} ) {
        $self->audit( "setting SIMSCAN_DEBUG");
        return "SIMSCAN_DEBUG=1
export SIMSCAN_DEBUG\n\n";
    };

    return '';
};

sub smtp_auth_enable {
    my $self = shift;

    return '' if ! $self->conf->{'smtpd_auth_enable'};

    my $smtp_auth = '';

    $self->audit( "build_smtp_run: enabling SMTP-AUTH");

    # deprecated, should not be used any longer
    if ( $self->conf->{'smtpd_hostname'} && $self->conf->{'qmail_smtpd_auth_0.31'} ) {
        $self->audit( "  configuring smtpd hostname");
        $smtp_auth .= $self->toaster->supervised_hostname( 'smtpd' );
    }

    my $chkpass = $self->_set_checkpasswd_bin( prot => 'smtpd' )
        or return '';

    return "$smtp_auth $chkpass /usr/bin/true ";
}

sub smtp_set_qmailqueue {
    my $self = shift;
    my %p = validate( @_, { 'prot' => { type=>SCALAR,  optional=>1 } } );

    my $prot = $p{'prot'};
    my $qdir = $self->get_qmail_dir;

    if ( $self->conf->{'filtering_method'} ne "smtp" ) {
        $self->audit( "filtering_method != smtp, not setting QMAILQUEUE.");
        return '';
    }

    # typically this will be simscan, qmail-scanner, or qmail-queue
    my $queue = $self->conf->{'smtpd_qmail_queue'} || "$qdir/bin/qmail-queue";

    if ( defined $prot && $prot eq "submit" ) {
        $queue = $self->conf->{'submit_qmail_queue'};
    }

    # if the selected one is not executable...
    if ( ! -x $queue ) {

        return $self->error( "$queue is not executable by uid $>.", fatal => 0)
            if !-x "$qdir/bin/qmail-queue";

        warn "WARNING: $queue is not executable! I'm falling back to
$qdir/bin/qmail-queue. You need to either (re)install $queue or update your
toaster-watcher.conf file to point to its correct location.\n
You will continue to get this notice every 5 minutes until you fix this.\n";
        $queue = "$qdir/bin/qmail-queue";
    }

    $self->audit( "  using $queue for QMAILQUEUE");

    return "QMAILQUEUE=\"$queue\"\nexport QMAILQUEUE\n\n";
}

sub smtp_set_rbls {
    my $self = shift;

    return q{} if ( ! $self->conf->{'rwl_enable'} && ! $self->conf->{'rbl_enable'} );

    my $rbl_cmd_string;

    my $rblsmtpd = $self->util->find_bin( "rblsmtpd" );
    $rbl_cmd_string .= "\\\n\t$rblsmtpd ";

    $self->audit( "smtp_set_rbls: using rblsmtpd");

    my $timeout = $self->conf->{'rbl_timeout'} || 60;
    $rbl_cmd_string .= $timeout != 60 ? "-t $timeout " : q{};

    $rbl_cmd_string .= "-c " if  $self->conf->{'rbl_enable_fail_closed'};
    $rbl_cmd_string .= "-b " if !$self->conf->{'rbl_enable_soft_failure'};

    if ( $self->conf->{'rwl_enable'} && $self->conf->{'rwl_enable'} > 0 ) {
        my $list = $self->get_list_of_rwls();
        foreach my $rwl (@$list) { $rbl_cmd_string .= "\\\n\t\t-a $rwl " }
        $self->audit( "tested DNS white lists" );
    }
    else { $self->audit( "no RWLs selected"); };

    if ( $self->conf->{'rbl_enable'} && $self->conf->{'rbl_enable'} > 0 ) {
        my $list = $self->get_list_of_rbls();
        $rbl_cmd_string .= $list if $list;
        $self->audit( "tested DNS blacklists" );
    }
    else { $self->audit( "no RBLs selected") };

    return "$rbl_cmd_string ";
};

sub supervised_hostname_qmail {
    my $self = shift;
    my $prot = shift or croak "missing prot!";

    my $qsupervise = $self->get_supervise_dir;

    my $prot_val = "qmail_supervise_" . $prot;
    my $prot_dir = $self->conf->{$prot_val} || "$qsupervise/$prot";

    $self->audit( "supervise dir is $prot_dir");

    if ( $prot_dir =~ /^qmail_supervise\/(.*)$/ ) {
        $prot_dir = "$qsupervise/$1";
        $self->audit( "expanded supervise dir to $prot_dir");
    }

    my $qmaildir = $self->get_qmail_dir;
    my $me = "$qmaildir/control/me"; # the qmail file for the hostname

    my @lines = <<EORUN
LOCAL=\`head -1 $me\`
if [ -z \"\$LOCAL\" ]; then
    echo ERROR: $prot_dir/run tried reading your hostname from $me and failed!
    exit 1
fi\n
EORUN
;
    $self->audit( "hostname set to contents of $me");

    return @lines;
}

sub test_each_rbl {
    my $self = shift;
    my %p = validate( @_, {
            'rbls'    => { type=>ARRAYREF },
            $self->get_std_opts,
        },
    );

    my $rbls = $p{'rbls'};

    my @valid_dnsbls;
    foreach my $rbl (@$rbls) {
        if ( ! $rbl ) {
            $self->error("how did a blank RBL make it in here?", fatal=>0);
            next;
        };
        next if ! $self->dns->rbl_test( zone => $rbl );
        push @valid_dnsbls, $rbl;
    }
    return \@valid_dnsbls;
}

sub UpdateVirusBlocks {

    # deprecated function - no longer maintained.

    my $self = shift;
    my %p = validate( @_, { 'ips' => ARRAYREF, $self->get_std_opts } );

    my $ips   = $p{'ips'};
    my $time  = $self->conf->{'qs_block_virus_senders_time'};
    my $relay = $self->conf->{'smtpd_relay_database'};
    my $vpdir = $self->setup->vpopmail->get_vpop_dir;

    if ( $relay =~ /^vpopmail_home_dir\/(.*)\.cdb$/ ) {
        $relay = "$vpdir/$1";
    }
    else {
        if ( $relay =~ /^(.*)\.cdb$/ ) { $relay = $1; }
    }
    unless ( -r $relay ) { die "$relay selected but not readable!\n" }

    my @lines;

    my $verbose = 0;
    my $in     = 0;
    my $done   = 0;
    my $now    = time;
    my $expire = time + ( $time * 3600 );

    print "now: $now   expire: $expire\n" if $verbose;

    my @userlines = $self->util->file_read( $relay );
  USERLINES: foreach my $line (@userlines) {
        unless ($in) { push @lines, $line }
        if ( $line =~ /^### BEGIN QMAIL SCANNER VIRUS ENTRIES ###/ ) {
            $in = 1;

            for (@$ips) {
                push @lines,
"$_:allow,RBLSMTPD=\"-VIRUS SOURCE: Block will be automatically removed in $time hours: ($expire)\"\n";
            }
            $done++;
            next USERLINES;
        }

        if ( $line =~ /^### END QMAIL SCANNER VIRUS ENTRIES ###/ ) {
            $in = 0;
            push @lines, $line;
            next USERLINES;
        }

        if ($in) {
            my ($timestamp) = $line =~ /\(([0-9]+)\)"$/;
            unless ($timestamp) {
                print "ERROR: malformed line: $line\n" if $verbose;
            }

            if ( $now > $timestamp ) {
                print "removing $timestamp\t" if $verbose;
            }
            else {
                print "leaving $timestamp\t" if $verbose;
                push @lines, $line;
            }
        }
    }

    if ($done) {
        if ($verbose) {
            foreach (@lines) { print "$_\n"; };
        }
        $self->util->file_write( $relay, lines => \@lines );
    }
    else {
        print
"FAILURE: Couldn't find QS section in $relay\n You need to add the following lines as documented in the toaster-watcher.conf and FAQ:

### BEGIN QMAIL SCANNER VIRUS ENTRIES ###
### END QMAIL SCANNER VIRUS ENTRIES ###

";
    }

    $self->setup->tcp_smtp( etc_dir => "$vpdir/etc" );
}

sub _memory_explanation {

    my ( $self, $prot, $maxcon ) = @_;
    my ( $sysmb,        $maxsmtpd,   $memorymsg,
        $perconnection, $connectmsg, $connections  );

    warn "\nbuild_${prot}_run: your "
      . "${prot}_max_memory_per_connection and "
      . "${prot}_max_connections settings in toaster-watcher.conf have exceeded your "
      . "${prot}_max_memory setting. I have reduced the maximum concurrent connections "
      . "to $maxcon to compensate. You should fix your settings.\n\n";

    if ( $OSNAME eq "freebsd" ) {
        $sysmb = int( substr( `/sbin/sysctl hw.physmem`, 12 ) / 1024 / 1024 );
        $memorymsg = "Your system has $sysmb MB of physical RAM.  ";
    }
    else {
        $sysmb     = 1024;
        $memorymsg =
          "This example assumes a system with $sysmb MB of physical RAM.";
    }

    $maxsmtpd = int( $sysmb * 0.75 );

    if ( $self->conf->{'install_mail_filtering'} ) {
        $perconnection = 40;
        $connectmsg    =
          "This is a reasonable value for systems which run filtering.";
    }
    else {
        $perconnection = 15;
        $connectmsg    =
          "This is a reasonable value for systems which do not run filtering.";
    }

    $connections = int( $maxsmtpd / $perconnection );
    $maxsmtpd    = $connections * $perconnection;

    warn <<EOMAXMEM;

These settings control the concurrent connection limit set by tcpserver,
and the per-connection RAM limit set by softlimit.

Here are some suggestions for how to set these options:

$memorymsg

smtpd_max_memory = $maxsmtpd # approximately 75% of RAM

smtpd_max_memory_per_connection = $perconnection
   # $connectmsg

smtpd_max_connections = $connections

If you want to allow more than $connections simultaneous SMTP connections,
you'll either need to lower smtpd_max_memory_per_connection, or raise
smtpd_max_memory.

smtpd_max_memory_per_connection is a VERY important setting, because
softlimit/qmail will start soft-bouncing mail if the smtpd processes
exceed this value, and the number needs to be sufficient to allow for
any virus scanning, filtering, or other processing you have configured
on your toaster.

If you raise smtpd_max_memory over $sysmb MB to allow for more than
$connections incoming SMTP connections, be prepared that in some
situations your smtp processes might use more than $sysmb MB of memory.
In this case, your system will use swap space (virtual memory) to
provide the necessary amount of RAM, and this slows your system down. In
extreme cases, this can result in a denial of service-- your server can
become unusable until the services are stopped.

EOMAXMEM

}

sub _test_smtpd_config_values {
    my $self = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my ( $fatal, $verbose ) = ( $p{fatal}, $p{verbose} );

    my $file = $self->util->find_config( "toaster.conf" );

    return $self->error( "qmail_dir does not exist as configured in $file" )
        if !-d $self->conf->{'qmail_dir'};

    # if vpopmail is enabled, make sure the vpopmail home dir exists
    return $self->error( "vpopmail_home_dir does not exist as configured in $file" )
        if ( $self->conf->{'install_vpopmail'} && !-d $self->conf->{'vpopmail_home_dir'} );

    # make sure qmail_supervise is set and is not a directory
    my $qsuper = $self->conf->{'qmail_supervise'};
    return $self->error( "conf->qmail_supervise is not set!" )
        if ( !defined $qsuper || !$qsuper );

    # make sure qmail_supervise is not a directory
    return $self->error( "qmail_supervise ($qsuper) is not a directory!" )
        if !-d $qsuper;

    return 1;
}

sub _smtp_sanity_tests {
    my $self = shift;
    my $qdir = $self->get_qmail_dir;

    return "if [ ! -f $qdir/control/rcpthosts ]; then
	echo \"No $qdir/control/rcpthosts!\"
	echo \"Refusing to start SMTP listener because it'll create an open relay\"
	exit 1
fi
";

}

sub _set_checkpasswd_bin {
    my $self = shift;
    my %p = validate( @_, { 'prot' => { type=>SCALAR } } );

    my $prot = $p{'prot'};

    $self->audit( "  setting checkpasswd for protocol: $prot");

    my $vdir = $self->conf->{'vpopmail_home_dir'}
        or return $self->error( "vpopmail_home_dir not set in \$conf" );

    my $prot_dir = $prot . "_checkpasswd_bin";
    $self->audit("  getting protocol directory for $prot from conf->$prot_dir");

    my $chkpass;
    $chkpass = $self->conf->{$prot_dir} or do {
        print "WARN: $prot_dir is not set in toaster-watcher.conf!\n";
        $chkpass = "$vdir/bin/vchkpw";
    };

    $self->audit( "  using $chkpass for checkpasswd");

    # vpopmail_home_dir is an alias, expand it
    if ( $chkpass =~ /^vpopmail_home_dir\/(.*)$/ ) {
        $chkpass = "$vdir/$1";
        $self->audit( "  expanded to $chkpass" );
    }

    return $self->error( "chkpass program $chkpass selected but not executable!")
        unless -x $chkpass;

    return "$chkpass ";
}


1;
__END__


=head1 NAME

Mail::Toaster:::Qmail - Qmail specific functions


=head1 SYNOPSIS

    use Mail::Toaster::Qmail;
    my $qmail = Mail::Toaster::Qmail->new();

    $qmail->install();

Mail::Toaster::Qmail is a module of Mail::Toaster. It contains methods for use with qmail, like starting and stopping the deamons, installing qmail, checking the contents of config files, etc. Nearly all functionality  contained herein is accessed via toaster_setup.pl.

See http://mail-toaster.org/ for details.


=head1 DESCRIPTION

This module has all sorts of goodies, the most useful of which are the build_????_run modules which build your qmail control files for you. See the METHODS section for more details.


=head1 SUBROUTINES/METHODS

An object of this class represents a means for interacting with qmail. There are functions for starting, stopping, installing, generating run-time config files, building ssl temp keys, testing functionality, monitoring processes, and training your spam filters.

=over 8

=item new

To use any of the methods following, you need to create a qmail object:

	use Mail::Toaster::Qmail;
	my $qmail = Mail::Toaster::Qmail->new();



=item build_pop3_run

	$qmail->build_pop3_run() ? print "success" : print "failed";

Generate a supervise run file for qmail-pop3d. $file is the location of the file it's going to generate. I typically use it like this:

  $qmail->build_pop3_run()

If it succeeds in building the file, it will install it. You should restart the service after installing a new run file.

 arguments required:
    file - the temp file to construct

 results:
    0 - failure
    1 - success


=item install_qmail_control_log_files

	$qmail->install_qmail_control_log_files();

Installs the files that control your supervised processes logging. Typically this consists of qmail-smtpd, qmail-send, and qmail-pop3d. The generated files are:

 arguments optional:
    prots - an arrayref list of protocols to build run files for.
           Defaults to [pop3,smtp,send,submit]

 Results:
    qmail_supervise/pop3/log/run
    qmail_supervise/smtp/log/run
    qmail_supervise/send/log/run
    qmail_supervise/submit/log/run


=item install_supervise_run

Installs a new supervise/run file for a supervised service. It first builds a new file, then compares it to the existing one and installs the new file if it has changed. It optionally notifies the admin.

  $qmail->build_smtp_run()

 arguments required:
 arguments optional:
 result:
    1 - success
    0 - error

=item netqmail_virgin

Builds and installs a pristine netqmail. This is necessary to resolve a chicken and egg problem. You can't apply the toaster patches (specifically chkuser) against netqmail until vpopmail is installed, and you can't install vpopmail without qmail being installed. After installing this, and then vpopmail, you can rebuild netqmail with the toaster patches.

 Usage:
   $qmail->netqmail_virgin( verbose=>1);

 arguments optional:
    package  - the name of the programs tarball, defaults to "netqmail-1.05"

 result:
    qmail installed.


=item send_start

	$qmail->send_start() - Start up the qmail-send process.

After starting up qmail-send, we verify that it's running before returning.


=item send_stop

  $qmail->send_stop()

Use send_stop to quit the qmail-send process. It will send qmail-send the TERM signal and then wait until it's shut down before returning. If qmail-send fails to shut down within 100 seconds, then we force kill it, causing it to abort any outbound SMTP sessions that are active. This is safe, as qmail will attempt to deliver them again, and again until it succeeds.


=item  restart

  $qmail->restart( prot=>"smtp")

Use restart to restart a supervised qmail process. It will send the TERM signal causing it to exit. It will restart immediately because it's supervised.


=item  supervised_hostname_qmail

Gets/sets the qmail hostname for use in supervise/run scripts. It dynamically creates and returns those hostname portion of said run file such as this one based on the settings in $conf.

 arguments required:
    prot - the protocol name (pop3, smtp, submit, send)

 result:
   an array representing the hostname setting portion of the shell script */run.

 Example result:

	LOCAL=`head -1 /var/qmail/control/me`
	if [ -z "$LOCAL" ]; then
		echo ERROR: /var/service/pop3/run tried reading your hostname from /var/qmail/control/me and failed!
		exit 1
	fi


=item  test_each_rbl

	my $available = $qmail->test_each_rbl( rbls=>$selected, verbose=>1 );

We get a list of RBL's in an arrayref, run some tests on them to determine if they are working correctly, and pass back the working ones in an arrayref.

 arguments required:
   rbls - an arrayref with a list of RBL zones

 result:
   an arrayref with the list of the correctly functioning RBLs.


=item  build_send_run

  $qmail->build_send_run() ? print "success";

build_send_run generates a supervise run file for qmail-send. $file is the location of the file it's going to generate.

  $qmail->build_send_run() and
        $qmail->restart( prot=>'send');

If it succeeds in building the file, it will install it. You can optionally restart qmail after installing a new run file.

 arguments required:
   file - the temp file to construct

 results:
   0 - failure
   1 - success


=item  build_smtp_run

  if ( $qmail->build_smtp_run( file=>$file) ) { print "success" };

Generate a supervise run file for qmail-smtpd. $file is the location of the file it's going to generate.

  $qmail->build_smtp_run()

If it succeeds in building the file, it will install it. You can optionally restart the service after installing a new run file.

 arguments required:
    file - the temp file to construct

 results:
    0 - failure
    1 - success


=item  build_submit_run

  if ( $qmail->build_submit_run( file=>$file ) ) { print "success"};

Generate a supervise run file for qmail-smtpd running on submit. $file is the location of the file it's going to generate.

  $qmail->build_submit_run( file=>$file );

If it succeeds in building the file, it will install it. You can optionally restart the service after installing a new run file.

 arguments required:
    file - the temp file to construct

 results:
    0 - failure
    1 - success


=item  check_service_dir

Verify the existence of the qmail service directory (typically /service/[smtp|send|pop3]).

 arguments required:
    dir - the directory whose existence we test for

 results:
    0 - failure
    1 - success


=item  check_rcpthosts

  $qmail->check_rcpthosts;

Checks the control/rcpthosts file and compares its contents to users/assign. Any zones that are in users/assign but not in control/rcpthosts or control/morercpthosts will be presented as a list and you will be expected to add them to morercpthosts.

 arguments required:
    none

 arguments optional:
    dir - defaults to /var/qmail

 result
    instructions to repair any problem discovered.


=item  config

Qmail is nice because it is quite easy to configure. Just edit files and put the right values in them. However, many find that a problem because it is not so easy to always know the syntax for what goes in every file, and exactly where that file might be. This sub takes your values from toaster-watcher.conf and puts them where they need to be. It modifies the following files:

   /var/qmail/control/concurrencyremote
   /var/qmail/control/me
   /var/qmail/control/mfcheck
   /var/qmail/control/spfbehavior
   /var/qmail/control/tarpitcount
   /var/qmail/control/tarpitdelay
   /var/qmail/control/sql
   /var/qmail/control/locals
   /var/qmail/alias/.qmail-postmaster
   /var/qmail/alias/.qmail-root
   /var/qmail/alias/.qmail-mailer-daemon

  FreeBSD specific:
   /etc/rc.conf
   /etc/mail/mailer.conf
   /etc/make.conf

You should not manually edit these files. Instead, make changes in toaster-watcher.conf and allow it to keep them updated.

 Usage:
   $qmail->config();

 results:
    0 - failure
    1 - success


=item  control_create

To make managing qmail a bit easier, we install a control script that allows the administrator to interact with the running qmail processes.

 Usage:
   $qmail->control_create();

 Sample Output
    /usr/local/sbin/qmail {restart|doqueue|flush|reload|stat|pause|cont|cdb|queue|help}

    # qmail help
	        pause -- temporarily stops mail service (connections accepted, nothing leaves)
	        cont -- continues paused mail service
	        stat -- displays status of mail service
	        cdb -- rebuild the cdb files (tcp.smtp, users, simcontrol)
	        restart -- stops and restarts smtp, sends qmail-send a TERM & restarts it
	        doqueue -- sends qmail-send ALRM, scheduling queued messages for delivery
	        reload -- sends qmail-send HUP, rereading locals and virtualdomains
	        queue -- shows status of queue
	        alrm -- same as doqueue
	        hup -- same as reload

 results:
    0 - failure
    1 - success


=item  get_domains_from_assign

Fetch a list of domains from the qmaildir/users/assign file.

  $qmail->get_domains_from_assign;

 arguments required:
    none

 arguments optional:
    match - field to match (dom, uid, dir)
    value - the pattern to  match

 results:
    an array


=item  get_list_of_rbls

Gets passed a hashref of values and extracts all the RBLs that are enabled in the file. See the toaster-watcher.conf file and the rbl_ settings therein for the format expected. See also the t/Qmail.t for examples of usage.

  my $r = $qmail->get_list_of_rbls( verbose => $verbose );

 result:
   an arrayref of values


=item  get_list_of_rwls

  my $selected = $qmail->get_list_of_rwls( verbose=>$verbose);

Here we collect a list of the RWLs from the configuration file that gets passed to us and return them.

 result:
   an arrayref with the enabled rwls.


=item  install_qmail

Builds qmail and installs qmail with patches (based on your settings in toaster-watcher.conf), installs the SSL certs, adjusts the permissions of several files that need it.

 Usage:
   $qmail->install_qmail( verbose=>1);

 arguments optional:
     package  - the name of the programs tarball, defaults to "qmail-1.03"

 result:
     one kick a55 mail server.

Patch info is here: http://mail-toaster.org/patches/


=item  install_qmail_control_files

When qmail is first installed, it needs some supervised run files to run under tcpserver and daemontools. This sub generates the qmail/supervise/*/run files based on your settings. Perpetual updates are performed by toaster-watcher.pl.

  $qmail->install_qmail_control_files;

 arguments optional:

 result:
    qmail_supervise/pop3/run
    qmail_supervise/smtp/run
    qmail_supervise/send/run
    qmail_supervise/submit/run



=back

=head1 EXAMPLES

Working examples of the usage of these methods can be found in  t/Qmail.t, toaster-watcher.pl, and toaster_setup.pl.


=head1 DIAGNOSTICS

All functions include verbose output which is enabled by default. You can disable the status/verbose messages by calling the functions with verbose=>0. The default behavior is to die upon errors. That too can be overriddent by setting fatal=>0. See the tests in t/Qmail.t for code examples.


  #=head1 COMMON USAGE MISTAKES



=head1 CONFIGURATION AND ENVIRONMENT

Nearly all of the configuration options can be manipulated by setting the
appropriate values in toaster-watcher.conf. After making changes in toaster-watcher.conf,
you can run toaster-watcher.pl and your changes will propagate immediately,
or simply wait a few minutes for them to take effect.


=head1 DEPENDENCIES

A list of all the other modules that this module relies upon, including any
restrictions on versions, and an indication whether these required modules are
part of the standard Perl distribution, part of the module's distribution,
or must be installed separately.

    Params::Validate        - from CPAN
    Mail::Toaster           - with package


=head1 BUGS AND LIMITATIONS

None known. When found, report to author.
Patches are welcome.


=head1 TODO


=head1 SEE ALSO

  Mail::Toaster
  Mail::Toaster::Conf
  toaster.conf
  toaster-watcher.conf

 http://mail-toaster.org/


=head1 AUTHOR

Matt Simerson  (matt@tnpi.net)


=head1 ACKNOWLEDGEMENTS


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2004-2012 The Network People, Inc. (info@tnpi.net). All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
