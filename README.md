NAME
    toaster_setup.pl - build and testing CLI for Mail::Toaster 5

NOTICE
    Mail::Toaster 5 is no longer under active development. Development has
    moved to [Mail Toaster 6](https://github.com/msimerson/Mail-Toaster-6/wiki).

SYNOPSIS
    toaster_setupl.pl is the front end to everything you need to turn a
    computer into a secure, full-featured, high-performance mail server.

       toaster_setup.pl -s <help> [-d]

          -s[ection] - see OPTIONS AND ARGUMENTS section for choices
          -v[erbose] - enable verbose output

    A really good place to start is:

       toaster_setupl.pl -s help | less

DESCRIPTION
    The mail toaster is a collection of open-source software which provides
    a full-featured mail server running on FreeBSD, Mac OS X, and Linux. The
    system is built around the qmail mail transport agent, with many
    additions and modifications. Matt Simerson is the primary author and
    maintainer of the toaster. There is an active and friendly community of
    toaster owners which supports the toaster on a mailing list and web
    forum.

    The toaster is built around qmail, a robust mail transfer agent by
    Daniel J. Bernstein, and vpopmail, a virtual domain manager by Inter7
    systems. Matt keeps up with releases of the core software, evaluates
    them, decides when they are stable, and then integrates them into the
    toaster. Matt has also added several patches which add functionality to
    these core programs.

    A complete set of instructions for building a mail toaster are on the
    toaster install page. There is a substantial amount of documentation
    available for the "Mail::Toaster" toaster. Much of it is also readable
    via "perldoc Mail::Toaster", and the subsequent pages. Don't forget to
    read the Install, Configure, and FAQ pages on the web site. If you still
    have questions, there is a Web Forum and mailing list. Both are
    browseable and searchable for your convenience.


OPTIONS AND ARGUMENTS
      toaster_setup.pl -s <section> [-verbose]

               help - print this usage screen
             config - initial configuration of toaster*.conf files
                pre - installs a list of programs and libraries other toaster components need

                        Standard Daemons & Utilities
              mysql - installs MySQL
         phpmyadmin - installs phpMyAdmin
             apache - installs Apache
          apachessl - installs self signed SSL certs for Apache

                         Qmail and related tools
              ucspi - install ucspi-tcp w/MySQL patch
        daemontools - install daemontools
              ezmlm - install EzMLM idx
           vpopmail - installs vpopmail
          vpeconfig - configure ~vpopmail/etc/tcp.smtp
          vpopmysql - run the vpopmail MySQL grant and db create commands
            vqadmin - install vqadmin
              qmail - installs qmail with toaster patches
          qmailconf - configure various qmail control files
           netqmail - installs netqmail
        netqmailmac - installs netqmail with no patches
             djbdns - install the djbdns program

            courier - installs courier imap & pop3 daemons
        courierconf - post install configure for courier

                       Web Mail and Admin interfaces
         qmailadmin - installs qmailadmin
          sqwebmail - installs sqwebmail (webmail app)
       squirrelmail - installs squirrelmail (webmail app)
          roundcube - installs Roundcube (webmail app)

                         Mail Filtering
             filter - installs SpamAssassin, ClamAV, DCC, razor, and more
              razor - installs the razor2 agents
           maildrop - installs maildrop and mailfilter
             clamav - installs just ClamAV
            simscan - install simscan
            simconf - configure simscan
            simtest - run email tests to verify that simscan is working
       spamassassin - install and configure spamassassin
            allspam - activate spam filtering for all users

                      Logs, Statistics, and Monitoring
           maillogs - creates the mail logging directories
            socklog - installs socklog
            isoqlog - installs and configured isoqlog
          supervise - creates the directories to be used by svscan

               test - runs a complete test suite against your server
         filtertest - runs the simscan and qmail-scanner email scanner tests
           authtest - authenticates against pop, imap, and smtp servers
           proctest - check for processes that *should* be running
     imap|pop3|smtp - do authentication test for imap, pop3, or smtp-auth

            toaster - install Mail::Toaster
         logmonster - install Apache::Logmonster
            nictool - install nictool (http://www.nictool.com/)
                all - installs everything shown on the toaster INSTALL page

METHODS
    all
              toaster_setup.pl -s all

            a special target that tries to build the entire Mail::Toaster
            without any interaction from you. Unlike other targets, it will
            keep right on going when it encounters an error, getting as much
            built as it possibly can. It is presumed that the administrator
            is logging the output for later review. I use this target
            primarily in testing.

AUTHOR
    Matt Simerson (matt@tnpi.net)

SEE ALSO
    The following are all man/perldoc pages:

      Mail::Toaster::Conf
      toaster.conf
      toaster-watcher.conf

      Mail::Toaster
      Mail::Toaster::Apache
      Mail::Toaster::CGI
      Mail::Toaster::DNS
      Mail::Toaster::Darwin
      Mail::Toaster::Ezmlm
      Mail::Toaster::FreeBSD
      Mail::Toaster::Logs
      Mail::Toaster::Mysql
      Mail::Toaster::Qmail
      Mail::Toaster::Setup
      Mail::Toaster::Utility

      http://mail-toaster.org/
      http://mail-toaster.org/docs/
      http://mail-toaster.org/faq.shtml
      http://mail-toaster.org/changes.shtml

