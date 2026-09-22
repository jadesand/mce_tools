#!/usr/bin/env python

import numpy as np

import os
import subprocess
import time

from mce_control import mce_control
import auto_setup as ast

USAGE="""
%prog [options] stage

Configure the MCE for open loop noise measurements.  Basically:
 - turns off a bunch of biases
 - disables the servo
 - disables muxing
 - for SQ1 measurements, sets a fixed feedback at the current lock point.

The "stage" argument indicates the highest stage you want to leave
biased.  I.e.:

   preamp - turn off sa biases and sa offsets.
   sa     - turn off sq2 biases.
   sq2    - turn off muxing, sq1 biases.
   sq1    - turn off muxing, tes biases.  Requires a --row argument
            (and --ac2-cs, for two-level addressing).
   tes    - turn off muxing.  Requires a --row argument
            (and --ac2-cs, for two-level addressing).

This program is not good at turning things on carefully.  It is mostly
for turning things off.  So you probably want to run mce_reconfig
before you run this, or pass "--reconfig" to have the program pre-run
it for you.
"""

from optparse import OptionParser
o = OptionParser(usage=USAGE)
o.add_option('--config', default=None, type=str,
             help="tune config file.  If not provided, will use the default config file for the current setup.")
o.add_option('--row', default=None, type=int,
             help="specify row to lock (for sq1 and tes stages).")
o.add_option('--rc', default='1', type=str,
             help="specify rc that is working on.")
o.add_option('--reconfig', action='store_false', default=False,
             help="run mce_reconfig before setting up open loop.")
o.add_option('--frames', default=30, type=int)
o.add_option('--no-reinit', action='store_true',
             help="for tes and sq1 stages, do not re-init the servo before "
             "measuring the locking feedback.")
o.add_option('--keep-tes-bias', action='store_true', default=False,
             help="for the sq1 stage, do not zero tes bias. Use this when "
             "the caller wants to hold a nonzero tes bias across the freeze "
             "(e.g. superfast noise acquisition at a fixed bias point).")
o.add_option('--sq1lock', default='up', type="choice",
             choices=('up', 'dn'),
             help="which SQ1 lock point to use for the locking feedback: 'up' or 'dn'.  Default is 'up'.")
o.add_option('--ac2-cs', default=None, type=int,
             help="specify the ac2 chip-select address to hold on (for "
             "two-level addressing).  Required for sq1 and tes stages "
             "when config_two_level is set.")
opts, args = o.parse_args()

STAGES = ['preamp', 'sa', 'sq1', 'tes']

if len(args) != 1 or args[0] not in STAGES:
    o.error("Provide a single stage argument (%s)." % ','.join(STAGES))

stage = args[0]
if stage in ['sq1','tes'] and opts.row is None:
    o.error("The %s stage requires a --row argument." % stage)

is_two_level = int(subprocess.Popen(
    ["mas_param", "get", "config_two_level"],
    stdout=subprocess.PIPE).communicate()[0].split()[0])
if stage in ['sq1','tes'] and is_two_level and opts.ac2_cs is None:
    o.error("The %s stage requires a --ac2-cs argument when "
            "config_two_level is set." % stage)

if opts.rc == 'a':
    opts.rc = 1
else:
    opts.rc = int(opts.rc)


def read_and_zero(mce, card, param):
    """
    Read values from card,param.  Set them to zero in the MCE.  Return
    the read values.
    """
    vals = mce.read(card, param)
    mce.write(card, param, np.zeros(len(vals), 'int'))
    return vals

# Load config file
if opts.config is None:
    mas_path = ast.util.mas_path()
    exp_file = mas_path.experiment_file()
else:
    exp_file = opts.config
cfg = ast.config.configFile(exp_file)
tune_path = os.path.dirname(exp_file)


# Reconfigure?
if opts.reconfig:
    os.system('mce_reconfig')

# Get MCE
mce = mce_control()

if stage == 'sq1':
    if not opts.keep_tes_bias:
        read_and_zero(mce, 'tes', 'bias')

if stage in ['sq1', 'tes']:
    # Re-lock
    if not opts.no_reinit:
        mce.init_servo()
        time.sleep(0.1)
    
    # Check lock:
    print 'Columns that appear locked:'
    mce.data_mode(0)
    data = mce.read_data(opts.frames, row_col=True).data[opts.row,:,:]
    err, derr = data.mean(axis=-1), data.std(axis=-1)
    locked = (abs(err) < derr*2).astype('int')
    print locked

    # Measure the feedback.
    if opts.config is not None:
        print 'Pulling locking SQ1 feedbacks from tune=', tune_path
        # Load tune
        fs = ast.util.FileSet(tune_path)
        tuning = ast.util.tuningData(exp_file=fs.get('cfg_file'), data_dir='')
        
        sq = ast.SQ1Ramp.join([ast.SQ1Ramp(f) for f in fs.stage_all('sq1_ramp_check')])
        sq.tuning = tuning
        # Compute locking feedbacks from tune (and other useful info)
        sq.reduce()
        # Get data shape
        n_row, n_col, n_fb = sq.data_shape[-3:]
        # Generate a view of the locking feedbacks by row,col
        lock_x=sq.analysis['lock_%s_x'%opts.sq1lock].reshape(n_row, n_col)
        # Print locking feedbacks for desired row
        fb=lock_x[opts.row].astype('int')
    else:
        # Live fb readback only means anything once the MCE is closed-loop
        # (servo_mode=3, set by auto_setup's "operate" stage).  Only check
        # the columns we're actually reading; columns_off ones are left
        # at servo_mode=1 on purpose.
        col_start=(opts.rc-1)*8
        sq1_servo_mode = np.array(mce.read('sq1', 'servo_mode'))[col_start:col_start+8]
        cols_on = np.array(cfg['columns_off'][col_start:col_start+8]) == 0
        if not np.all(sq1_servo_mode[cols_on] == 3):
            raise RuntimeError(
                "sq1 servo_mode is %s for active columns, not 3 -- run "
                "auto_setup through 'operate', or pass --config."
                % list(sq1_servo_mode[cols_on]))
        mce.data_mode(1)
        data = mce.read_data(opts.frames, row_col=True).extract('fb')[opts.row,:,:]
        fb, dfb = data.mean(axis=-1), data.std(axis=-1)


    print 'Locking feedback:'
    # There may be a good reason the column is in columns_off ; ie we might
    # never want voltage down these SQ1FB lines.  Send 0V, for the SQ1FB
    # is -8192 DAC.
    #fb[np.where(locked==0)]=-8192 # zero for the sq1 fb lines is -8192
    columns_off=np.array(cfg['columns_off'][(opts.rc-1)*8:(opts.rc-1)*8+len(fb)])
    fb[np.where(columns_off==1)]=-8192
    print fb.astype('int')
    # Set fb_const (kill the servo below)
    mce.fb_const(fb.astype('int'))

    # Fix the row select/deselects first.
    ac_select=np.array(mce.read('ac', 'on_bias'))
    ac_deselect=np.array(mce.read('ac', 'off_bias'))
    ac_row_order=np.array(mce.read('ac','row_order'))
    for (ac_idx,(ac_sel,ac_desel)) in enumerate(zip(ac_select,ac_deselect)):
        if ac_idx==opts.row:
            ac_deselect[int(ac_row_order[ac_idx])]=ac_select[int(ac_row_order[ac_idx])]
        else:
            ac_select[int(ac_row_order[ac_idx])]=ac_deselect[int(ac_row_order[ac_idx])]

    mce.write('ac', 'on_bias', ac_select)
    mce.write('ac', 'off_bias', ac_deselect)

    # The chip select to hold on is given explicitly via --ac2-cs 
    if is_two_level:
        ac2_len=len(np.array(mce.read('ac2','row_order')))
        ac2_select=np.zeros(ac2_len, 'int')
        ac2_deselect=np.zeros(ac2_len, 'int')
        # ac2_on_bias in the config is per-chip-select (one entry per
        # unique address), matching cfg['ac2_row_order'].
        cs_idx=list(cfg['ac2_row_order']).index(opts.ac2_cs)
        ac2_select[opts.ac2_cs]=cfg['ac2_on_bias'][cs_idx]
        ac2_deselect[opts.ac2_cs]=cfg['ac2_on_bias'][cs_idx]

        mce.write('ac2', 'on_bias', ac2_select)
        mce.write('ac2', 'off_bias', ac2_deselect)

    # Sleep for a bit to let those biases get written, then disable mux.
    time.sleep(.1)
    # Reports from users indicate that setting enbl_mux=0 does not
    # work... so we set it to 1.
    ##mce.write('ac', 'enbl_mux', [0])
    mce.write('ac', 'enbl_mux', [1])
    if is_two_level:
        mce.write('ac2', 'enbl_mux', [1])

    # If fast-switching the SQ1 bias, set it to match the chosen row.
    # Also disable the SQ1 muxing.  Already chose SQ1 fb above.
    sq1_mux = mce.read('sq1', 'enbl_mux')
    if np.any(sq1_mux):
        sq1_bias=[]
        for c in range(len(sq1_mux)):
            sq1_bias.append(mce.read('sq1', 'bias_col%i'%c)[opts.row])
        # It is necessary to disable muxing before writing the new
        # (non fast-switching) SQ1 bias, otherwise it does not get
        # applied.
        mce.write('sq1', 'enbl_mux', np.zeros(len(sq1_mux)))
        time.sleep(.1)
        mce.write('sq1', 'bias', sq1_bias)

    # If fast-switching the SA fb, set it to match the chosen row.
    # Also disable the SA fb muxing.
    sa_mux = mce.read('sa', 'enbl_mux')
    if np.any(sa_mux):
        sa_fb=[]
        for c in range(len(sa_mux)):
            sa_fb.append(mce.read('sa', 'fb_col%i'%c)[opts.row])
        # It is necessary to disable muxing before writing the new
        # (non fast-switching) SA fb, otherwise it does not get
        # applied.
        mce.write('sa', 'enbl_mux', np.zeros(len(sa_mux)))
        time.sleep(.1)
        mce.write('sa', 'fb', sa_fb)

if stage == 'sa':
    # Kill the SQ1 bias and disable mux.
    read_and_zero(mce, 'ac', 'on_bias')
    read_and_zero(mce, 'ac', 'off_bias')
    time.sleep(.1)
    mce.write('ac', 'enbl_mux', [0])
    if is_two_level:
        read_and_zero(mce, 'ac2', 'on_bias')
        read_and_zero(mce, 'ac2', 'off_bias')
        time.sleep(.1)
        mce.write('ac2', 'enbl_mux', [0])
    # Also disable SQ1 muxing.  Hope you chose a good sq1 fb.
    sq1_mux = mce.read('sq1', 'enbl_mux')
    if np.any(sq1_mux):
        mce.write('sq1', 'enbl_mux', np.zeros(len(sq1_mux)))
    time.sleep(.1)

    # Kill the SQ1 bias
    read_and_zero(mce, 'sq1', 'bias')

    # Disable SA fb muxing
    sa_mux = mce.read('sa', 'enbl_mux')
    if np.any(sa_mux):
        mce.write('sa','enbl_mux', np.zeros(len(sa_mux)))
    time.sleep(.1)
    
    # It is necessary to disable muxing before writing the new
    # (non fast-switching) SA feedback, otherwise it does not get
    # applied.
    sa_fb = mce.read('sa', 'fb')
    mce.write('sa','fb',sa_fb)

if stage == 'preamp':
    read_and_zero(mce, 'sa', 'bias')
    read_and_zero(mce, 'sa', 'offset')

# You will probably want error mode data, with the servo off.
mce.servo_mode(1)
mce.data_mode(0)