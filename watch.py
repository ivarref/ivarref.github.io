#!/usr/bin/env python3

import fileinput
import subprocess
import traceback


def log_error(m):
    print(m, flush=True)

def log_info(m):
    print(m, flush=True)

def exec_verbose(args):
    try:
        res = subprocess.run(args, capture_output=True)
        if res.returncode != 0:
            log_error(f'Command {args}')
            log_error(f'Failed with exit code {res.returncode}')
            if 0 == len(res.stdout.splitlines()):
                log_error('Stdout: <empty>')
            else:
                log_error('Stdout:')
                log_error('=' * 80)
                for lin in res.stdout.splitlines():
                    try:
                        lin_decoded = lin.decode('utf-8')
                        log_error(lin_decoded)
                    except UnicodeDecodeError:
                        log_error(lin)
            if 0 == len(res.stderr.splitlines()):
                log_error('Stderr: <empty>')
            else:
                log_error('Stderr:')
                log_error('=' * 80)
                for lin in res.stderr.splitlines():
                    try:
                        lin_decoded = lin.decode('utf-8')
                        log_error(lin_decoded)
                    except UnicodeDecodeError:
                        log_error(lin)
                log_error('=' * 80)
            log_error(f'Command {args} failed with exit code {res.returncode}')
            return False
        else:
            log_info(f'CMD {str(args)} succeeded')
            sout = ''
            for lin in res.stdout.splitlines():
                try:
                    sout += lin.decode('utf-8')
                except UnicodeDecodeError:
                    sout += str(lin)
                sout += '\n'
            return True
    except FileNotFoundError as e:
        log_error(f'Executeable "{args[0]}" was not found!')
        log_error(f'Full command: {args}')
        raise e


def run_main():
    for line in fileinput.input():
        line = line.rstrip('\n')
        if line.startswith('Web Server is available at'):
            print(line, flush=True)
            exec_verbose(['osascript', 'refresh.scpt'])
        else:
            print(line, flush=True)


if __name__ == "__main__":
    run_main()
