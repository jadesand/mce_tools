#!/usr/bin/env python
import os
import re
import sys
import glob
import argparse
import subprocess

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

import mce_data

def load_runfile(run_path):
    """
    Parse an MCE .run file into a dict keyed by (card, param), e.g.
    d[('rc3', 'flx_quanta2')] -> ['2564'] (list of strings, as written).

    run_path: path to the .run file that accompanies a data file
              (data file 'foo' has runfile 'foo.run').
    """
    d = {}
    for line in open(run_path, 'r'):
        m = re.match(r'<(RB|WB) (\S+) (\S+)>\s*(.*)', line)
        if m:
            d[(m.group(2), m.group(3))] = m.group(4).split()
    return d

def load_flux_quanta(runfile, nrow, ncol):
    """
    Read flx_quanta for every (col, row) from an already-parsed .run file.

    runfile: dict returned by load_runfile()
    width:   number of rows to read per column (rows beyond this are dropped)

    Returns q[col, row] as int, shape (NUM_RC*NUM_COLS, width). q is in fb
    units per Phi0 (the flux-jump size programmed on that channel).
    A column/row with no flx_quanta entry (e.g. not present in this run) is 0.
    """
    q = np.zeros((ncol, nrow), dtype=int)
    chans_per_card = 8
    nrc = ncol // chans_per_card
    for rc in range(nrc):
        for ch in range(chans_per_card):
            key = ('rc%d' % (rc + 1), 'flx_quanta%d' % ch)
            if key in runfile:
                q[rc * chans_per_card + ch] = [int(x) for x in runfile[key][:nrow]]
    return q

def load_dead_mask(path, order_by='row'):
    """
    Load a dead_list config file (e.g. dead_squid1.cfg) into a boolean mask.
    Parses the ``n_rows``, ``n_cols``, and ``mask = [...]`` fields.
    Comments (``#`` to end of line and ``/* ... */``) are stripped before parsing.

    Parameters
    ----------
    path : str
        Path to the dead_list config file.
    order_by : str, optional
        Whether the mask values are ordered by row or by column in the config
        file. Must be either 'row' or 'col'. Default is 'row'.

    Returns
    -------
    np.ndarray
        A 2D boolean array of shape (n_rows, n_cols), where True indicates
        a dead channel (i.e., should be masked).
    """
    if isinstance(path, str):
        path = [path]

    mask = None
    for p in path:
        with open(p) as f:
            text = f.read()

        text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
        text = re.sub(r"#.*", "", text)

        n_rows = int(re.search(r"n_rows\s*=\s*(\d+)", text).group(1))
        n_cols = int(re.search(r"n_cols\s*=\s*(\d+)", text).group(1))

        mask_body = re.search(r"mask\s*=\s*\[(.*?)\]", text, flags=re.DOTALL).group(1)
        values = [int(v) for v in re.findall(r"-?\d+", mask_body)]

        expected = n_rows * n_cols
        if len(values) != expected:
            raise ValueError(
                "%s: expected %d mask values (%dx%d), found %d"
                % (path, expected, n_rows, n_cols, len(values))
            )

        mask_array = np.array(values, dtype=bool).reshape(n_rows, n_cols)
        if mask is None:
            mask = mask_array
        else:
            mask = np.logical_or(mask, mask_array)
    return mask

def unwrap_relock(fb, q):
    """
    Unwrap a single row's relock-every-point feedback trace, period q.

    fb: 1-D array of feedback values [fb units] in acquisition order
        (one relock-and-settle per point)
    q:  flx_quanta for this (col, row) [fb units per Phi0]

    Returns fb_unwrapped, same shape as fb, with the +-q ambiguity removed
    by choosing, at each step, the branch closest to the previous point:
        fb_unwrapped[0]   = fb[0]
        fb_unwrapped[i+1] = fb_unwrapped[i] + wrap(fb[i+1] - fb[i], q)
    where wrap(d, q) maps d into (-q/2, q/2] by subtracting the nearest
    multiple of q. This does NOT know about the unstable band: it will
    produce a smooth-looking but meaningless result across band points,
    since those are just random draws mod q, so the band still needs
    handling separately (next step).
    """
    fb = np.asarray(fb, dtype=float)
    d = np.diff(fb)
    d_wrapped = d - q * np.round(d / q)
    return np.r_[fb[0], fb[0] + np.cumsum(d_wrapped)]

def get_array_id():
    """
    Return the array_id configured for this experiment (mas_param get array_id),
    with surrounding quotes/whitespace stripped.
    """
    out = subprocess.Popen(
        ['mas_param', 'get', 'array_id'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE).communicate()[0]
    return out.strip().strip('"')

def load_dead_mask_for_array(array_id, nrow, ncol):
    """
    Load and OR together all dead_list cfg files for the given array_id, from
    $MAS_CONFIG/dead_lists/<array_id>/*.cfg.

    If no cfg files are found for this array_id, prints a warning and returns
    an all-False mask of shape (nrow, ncol) (i.e. no channel is marked dead).
    """
    mas_config = os.environ['MAS_CONFIG']
    pattern = os.path.join(mas_config, 'dead_lists', array_id, '*.cfg')
    paths = glob.glob(pattern)
    if not paths:
        print 'no dead_list cfg files found for array_id %r (%s); using all channels' % (array_id, pattern)
        return np.zeros((nrow, ncol), dtype=bool)
    return load_dead_mask(paths)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('folder')
    parser.add_argument('-r', '--nrow', type=int, required=True)
    parser.add_argument('-c', '--ncol', type=int, required=True)
    parser.add_argument('--columns', type=int, nargs='+',
                         help='columns to plot (default: all columns, 0..ncol-1)')
    parser.add_argument('-l', '--relock', action='store_true',
                         help='unwrap curves taken with relock (flx_lp_init) after every bias step')
    args = parser.parse_args()

    folder = args.folder
    nrow = args.nrow
    ncol = args.ncol
    columns = args.columns if args.columns is not None else range(ncol)
    relock = args.relock

    array_id = get_array_id()
    dead_mask = load_dead_mask_for_array(array_id, nrow, ncol)

    name = os.path.split(folder)[1]
    fn = os.path.join(folder, name)

    rf = load_runfile(fn + '.run')
    flux_quanta = load_flux_quanta(rf, nrow, ncol)

    biasfn = fn + '.bias'
    f = mce_data.MCEFile(fn)
    dname = os.path.split(fn)[0]
    bias = np.loadtxt(biasfn, skiprows=1)
    y = -1.0 * f.Read(row_col=True, unfilter='DC').data

    nr, nc, nt = y.shape
    print nc
    print nr

    cmap = plt.get_cmap('inferno')

    def get_trace(row, col):
        trace = y[row, col]
        if relock:
            q = flux_quanta[col, row]
            if q != 0:
                trace = unwrap_relock(trace, q)
        return trace

    for col in columns:
        print col,
        for row in range(0, nrow):
            sys.stdout.flush()
            plt.clf()
            plt.title('r%02dc%02d' % (row, col))
            plt.plot(bias, get_trace(row, col))

            if dead_mask[row, col]:
                plt.text(0.02, 0.98, 'dead', transform=plt.gca().transAxes,
                         ha='left', va='top', color='red')

            fn_s = os.path.join(dname, 'iv_col%02d_row%02d.png' % (col, row))
            plt.xlabel('Bias Current (arbitrary units)')
            plt.ylabel('SQ1FB (arbitrary units)')
            plt.grid()
            plt.savefig(fn_s)

        plt.clf()
        plt.title('c%02d all rows' % col)
        for row in range(0, nrow):
            if dead_mask[row, col]:
                continue
            color = cmap(float(row) / max(nrow - 1, 1))
            plt.plot(bias, get_trace(row, col), color=color, label='r%02d' % row)

        fn_col = os.path.join(dname, 'iv_col%02d_allrows.png' % col)
        plt.xlabel('Bias Current (arbitrary units)')
        plt.ylabel('SQ1FB (arbitrary units)')
        plt.grid()
        plt.savefig(fn_col)

    print ''

if __name__=='__main__':
  main()
