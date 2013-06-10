#!/usr/bin/env python
import os
import sys
import gtk # ensure that the application name is correctly set
import gnomekeyring as gkey
import getpass
import subprocess
import time
import signal
import string

class Keyring(object):
    #
    # Original author: http://www.rittau.org/blog/20070726-01
    # Original code: http://www.rittau.org/gnome/python/keyring.py
    #

    def __init__(self, name, server, protocol):

        self._name = name
        self._server = server
        self._protocol = protocol
        self._keyring = gkey.get_default_keyring_sync()

    def has_credentials(self):
        try:
            attrs = {"server": self._server, "protocol": self._protocol}
            items = gkey.find_items_sync(gkey.ITEM_NETWORK_PASSWORD, attrs)
            return len(items) > 0
        except gkey.DeniedError:
            return False

    def get_credentials(self):
        attrs = {"server": self._server, "protocol": self._protocol}
        items = gkey.find_items_sync(gkey.ITEM_NETWORK_PASSWORD, attrs)
        return (items[0].attributes["user"], items[0].secret)

    def set_credentials(self, (user, pw)):
        attrs = {
                "user": user,
                "server": self._server,
                "protocol": self._protocol,
            }
        gkey.item_create_sync(gkey.get_default_keyring_sync(),
                gkey.ITEM_NETWORK_PASSWORD, self._name, attrs, pw, True)

#
# Wrap the imapfilter binary since it doesn't handle bad server connections
# well.  It needs to be restarted when it crashes.
#
class ImapFilterWrapper(object):

    def __init__(self, **kwargs):
        self.name = os.path.basename(sys.argv[0])
        self.verbose = kwargs.get('verbose', False)
        self.debug = kwargs.get('debug', False)
        self.daemonize = kwargs.get('daemonize', True)

        self.home = os.getenv('HOME') + '/.imapfilter'
        self.pidfile = self.home + '/wrapper.pid'

    def delete_pid(self):
        f = os.remove(self.pidfile)

    def write_pid(self):
        with os.fdopen(os.open(self.pidfile, os.O_WRONLY | os.O_CREAT, 0600), 'w') as f:
            f.write(str(self.pid))

    def quit(self, signum, frame):
        print '{}: killed by signal {}'.format(self.name, signum)
        if self.p:
            self.p.terminate()
        self.delete_pid()
        os._exit(0)

    def run(self):
        os.chdir(self.home)

        imapfilter_cmd = ['imapfilter']

        if self.verbose:
            imapfilter_cmd.append('-v')

        if self.debug:
            log_debug = self.home + '/debug.log'
            print 'Debug Log = {}'.format(log_debug)
            imapfilter_cmd.append('-d')
            imapfilter_cmd.append(log_debug)

        if self.daemonize:
            if os.fork() != 0:
                os._exit(0)

            os.setsid()

            fd = os.open('/dev/null', os.O_RDONLY)
            os.dup2(fd, 0)

            log = os.open(self.home + '/imapfilter.log', os.O_WRONLY | os.O_CREAT, 0600)
            os.dup2(log, 1)
            os.dup2(log, 2)


        self.pid = os.getpid()
        signal.signal(signal.SIGHUP, self.quit)
        signal.signal(signal.SIGINT, self.quit)
        signal.signal(signal.SIGTERM, self.quit)
        self.write_pid()

        # Point to dbus for keyring access in the event this isn't started
        # from a local GNOME session.  This expects another shell script to
        # write this file from something like .bashrc
        my_env = os.environ.copy()
        with open(my_env['HOME'] + '/.dbus-session') as f:
            my_env['DBUS_SESSION_BUS_ADDRESS'] = f.read().strip()

        while True:
            self.p = subprocess.Popen(imapfilter_cmd, env=my_env)
            print("{}: started {} with pid {}".format(self.name, imapfilter_cmd, self.p.pid))
            self.p.wait()
            time.sleep(30)

#
# Main function, either run keyring or run the wrapper
#
if __name__ == '__main__':

    if len(sys.argv) > 1:
        action = sys.argv[1]
    else:
        action = 'imapfilter'


    if action == 'keyring':

        keyring_action = sys.argv[2]
        server = sys.argv[3]

        keyring = Keyring('IMAP Filter ' + server, server, 'imap')

        if keyring_action == 'set':
            user = raw_input("Username: ")
            secret = getpass.getpass()
            keyring.set_credentials((user, secret))
        elif keyring_action == 'get':
            user, secret = keyring.get_credentials()
            key = sys.argv[4]
            if key == 'password':
                print secret
            else:
                print user

    # action == 'imapfilter'
    else:
        #wrapper = ImapFilterWrapper(verbose=True, daemonize=False)
        wrapper = ImapFilterWrapper(verbose=True, daemonize=True)
        wrapper.run()

