#!/usr/bin/env python

import os
import re
import sys

from subprocess import Popen, PIPE

parentre = re.compile(r'^# Parent\s+([a-f0-9]{40})', re.M)
numre = re.compile(r'^[0-9]*')

def to_i(text):
    return int(numre.match('0' + text).group(0))

def notify(message, title='Applying patches', icon=None):
    os.spawnlp(os.P_NOWAIT, 'notify-send', 'notify-send', '-i', icon or 'none', title, message)

def run(args, check=True, log=True):
    p = Popen(args, stdout=PIPE, stderr=PIPE)
    out, err = p.communicate()
    retcode = p.poll()
    if log:
        with open('/tmp/patchlog.log', 'a') as f:
            f.write('-----\n%s\nexitcode: %d\n%s\n%s\n' % (' '.join(args), retcode, out, err))
    if retcode != 0 and check:
        msg = 'Failed to run %s' % ' '.join(args)
        raise RuntimeError("Failed to run hg %s" % ' '.join(args))
    return retcode, (out, err)

def extract_parent(content):
    m = parentre.search(content)
    if m:
        return m.group(1)

def extract_title(content):
    state = 0
    for line in content.splitlines():
        if state == 0 and line.find('# HG changeset patch') >= 0:
            state = 1
        elif state == 1 and not line.startswith('#'):
            return line
    return '<unknown title>'

def read_titles(filenames):
    return [extract_title(open(path).read()) for path in filenames]

def apply_patches(dest, filenames):
    if not filenames:
        notify('Nothing to patch')
        return

    os.chdir(dest)

    # write filenames for easier manual inspection
    with open('/tmp/plist', 'w') as f:
        f.write('\n'.join(filenames) + '\n')

    # get which commit the patch is based on
    fallback_ref = '@'
    ref = extract_parent(open(filenames[0]).read())

    # update to where the author started, or the "@" place
    if ref:
        ret = run(['hg', 'update', '-C', ref], check=False)[0]
    if not ref or ret != 0:
        ref = fallback_ref
        ret = run(['hg', 'update', '-C', ref], check=False)

    # create a bookmark
    bkname = 'p%d' % to_i(os.path.basename(filenames[0]))
    run(['hg', 'bookmark', '-f', bkname])

    # apply patches
    ret = run(['hg', 'import', '--partial'] + filenames, check=False)[0]
    if ret == 0 or ret == 1:
        notify('%d patches applied at %s%s\n\n%s:'
               % (len(filenames), ref[0:7], ret == 1 and ' (with fuzz)' or '',
                  '\n'.join(read_titles(filenames))),
               title='Patched branch: %s' % bkname, icon='edit-copy')
    return 0 if ret == 1 else ret

dest = os.path.expanduser(os.environ.get('PATCH_DEST', '~/hg-draft'))
sys.exit(int(apply_patches(dest, sys.argv[1:])))
