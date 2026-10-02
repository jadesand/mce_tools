#!/usr/bin/python

# 0. User specifies a row
# 1a. Write row_order to contain only that row
# 1b. Set all rows to const_mode (so it never switches) and set const_val = 0 EXCEPT desired row
# 4. Set adc offsets for all rows to match that row's values; now the MCE is in closed loop and multiplexing but sitting still
# 5. clear the PID parameters
# 6. pause 1 second (?)
# 7. freeze_servo

# 090619 JPF Added enbl_mux = 0
# 090624 JPF Removed enbl_mux = 0, added mode to read in a file rather than frames directly
# 090713 JPF Added feature for BAC configuration
# 090729 JPF Fixed behavior with nonzero off_bias (NO: we still need to use zeros, since we have zeros applied during SQ2SERVO operation)
# 091020 JPF Set other SQ1s to their off_biases rather than to zero, add option not to do this
# 110405 JPF HACKED to make fast SQ2 feedback work with a fast-switching BC
# 110930 JPF Fixed to make fast SQ2 feedback work with a fast-switching BC; now turns off muxing on SQ1/2

import sys, time, os
sys.path.append('/home/bicep3/python_tools')
sys.path.append('/usr/mce/mce_script/python')
# sys.path.append('/home/bicep3/rshi/local/mas/swig')# doesn't work
# sys.path.append('/home/bicep3/shawn/mas_931/swig') # doesn't work
# sys.path.append('/src/mas/swig')
from glob import *
from optparse import OptionParser
from numpy import *

# from mce import mce as MCE
from pymce import MCE as mce

from mce_data import *

# hard-coded constants and flags
MCE_COLS = 8

# parse command line arguments
o = OptionParser()
o.add_option('-n','--n-frames',type='int',default=100,dest='n_frames',
             help='number of frames to average when determining feedback')
o.add_option('-r','--row',type='int',default=0,dest='row',
             help='the row to use for all columns')
o.add_option('--restore',action='store_true',default=False,dest='restore',
             help='restart the MCE servo (servo_mode=3 + flx_lp_init)')
o.add_option('--o','--open',action='store_true',default=False,dest='do_open',
             help='Freeze with the PID servo inactive (servo_mode=0)')
o.add_option('--save',action='store_false',default=True,dest='do_direct_acq',
             help='Save and read back files, rather than reading frames directly')
o.add_option('--zero_sq1_off',action='store_true',default=False,dest='zero_sq1_off',
             help='Turn the other SQ1s to zero bias, rather the current off_bias')
o.add_option('--sq1_nomux',action='store_true',default=False,dest='sq1_nomux',
             help='Fully disable multiplexing for SQ1')
opts, args = o.parse_args()

# get an MCE interface object
m = mce()
# m = MCE()

# Determine name and number of readout cards
n_rc = len(m.read('rca', 'data_mode'))
n_cols = n_rc * MCE_COLS
n_rows = m.read('cc', 'num_rows_reported', array=False)

print('n_rc = ', n_rc)
print('n_cols = ', n_cols)
print('n_rows = ', n_rows)


# check whether we have fast SQ2 switching # Commented out for B3
#use_fastSQ2 = True
#try:
#    dummy = m.read('sq2','fb_col0')
#except MCEError:
#    use_fastSQ2 = False

time.sleep(1)

# check whether our row is OK
row = opts.row
if row not in range(0,n_rows):
    print 'Error: invalid row number!'
    sys.exit(10)
row_order = m.read('ac','row_order')
if row not in row_order:
    print 'Error: row not in current row_order!'
    sys.exit(10)

# SET PID LOOP TO STARTING CONFIGURATION
m.write('rca','servo_mode',[3]*MCE_COLS)
time.sleep(0.5)
m.write('rca', 'flx_lp_init', [1])
time.sleep(1)

# STOP MCE ON SPECIFIED ROW
print 'Stopping MUX at row ', row
# set the SQ1 biases => off for all rows
# NOTE: we need to do this BEFORE changing row order!
# first, read the old values for later
on_bias = m.read('ac','on_bias')
time.sleep(0.1)
off_bias = m.read('ac','off_bias')
time.sleep(0.1)
if opts.zero_sq1_off:
    # turn every row to zero bias
    new_off_bias = [0]*41
    new_on_bias = [0]*41
else:
    # turn every row to its off bias
    new_off_bias = off_bias
    new_on_bias = off_bias
m.write('ac','on_bias',new_on_bias)
m.write('row','select',new_on_bias) #changed from sq1, for B3
time.sleep(0.2)
m.write('ac','off_bias',new_off_bias)
m.write('row','deselect',new_off_bias) # changed from sq1, for B3
time.sleep(1)

# reset the row_order to strobe just the desired row
m.write('ac','row_order',[row]*41)
time.sleep(0.2)

# re-bias this SQ1 only
new_on_bias[row] = on_bias[row]
time.sleep(0.1)
m.write('ac','on_bias',new_on_bias)
m.write('row','select',new_on_bias) # changed from sq1, for B3
time.sleep(0.1)
m.write('rca', 'flx_lp_init', [1])
time.sleep(0.1)

# stop muxing for the BAC (or fast-switching BC2) too #commented out for B3
cv = zeros(n_cols,int)
#if use_fastSQ2:
#    for col in range(0,n_cols):
#        fb2val = m.read('sq2','fb_col%d'%(col))
#        m.write('sq2','fb_col%d'%(col),[fb2val[row]]*41)
#        time.sleep(0.01)
#m.write('sq2','enbl_mux',[0])
time.sleep(0.01)

# SET ALL ADC OFFSETS TO BE THE SAME
# (avoids bizarre feedback values)
adc_offsets = zeros(n_cols,int)
for rc in range(0,n_rc):
    for col in range(0,MCE_COLS):
        adc_offsets[rc*MCE_COLS+col] = m.read('rc%d'%(rc+1),'adc_offset%d'%(col))[row]
new_adc_offsets = tile(adc_offsets,(41,1))

print('adc_offsets =', adc_offsets)
print('new_adc_offsets =', new_adc_offsets)

print 'setting adc offsets to match desired row'
for rc in range(0,n_rc):
    for col in range(0,MCE_COLS):
        m.write('rc%d'%(rc+1),'adc_offset%d'%col,new_adc_offsets[:,rc*MCE_COLS+col].tolist())
        time.sleep(0.01)
time.sleep(0.1)
m.write('rca', 'flx_lp_init', [1])
time.sleep(0.1)

print 'setting sq1 bias to match desired row - reading sq1 bias from fast switching values'
new_sq1_bias = zeros(n_cols,int)
for col in range(n_cols):
    new_sq1_bias[col] = m.read('sq1','bias_col%d'%col)[row]
print 'new sq1 bias: ', new_sq1_bias
for col in range(n_cols):
    m.write('sq1','bias_col%d'%col, [new_sq1_bias[col]]*41)
    time.sleep(0.01)
time.sleep(0.1)

print 'setting sa fb to match desired row - reading sa fb from fast switching values'
new_sa_fb = zeros(n_cols,int)
for col in range(n_cols):
    new_sa_fb[col] = m.read('sa','fb_col%d'%col)[row]
print 'new sa fb: ', new_sa_fb
for col in range(n_cols):
    m.write('sa','fb_col%d'%col, [new_sa_fb[col]]*41)
    time.sleep(0.01)
time.sleep(0.1)

# set the off_bias of this row to match the on_bias (remove SQ1 strobe)
print 'setting off_bias to match on_bias for this row'
new_off_bias[row]=on_bias[row]
m.write('ac','off_bias',new_off_bias)
m.write('row','deselect',new_off_bias) # changed from sq1, for B3
time.sleep(0.1)
m.write('rca', 'flx_lp_init', [1])

time.sleep(0.2)

# disable mux if requested
# (N.B.: I previously marked this as "BAD - do not do this!"...)
if opts.sq1_nomux:
    print 'disabling SQ1 switching entirely'
    try:
        m.write('ac','const_val',new_on_bias)
        m.write('ac','enbl_mux',[0]*41)
    except ParamError:
        print 'WARNING: cannot disable SQ1 muxing.  AC.const_val not enabled in mce.cfg'
    time.sleep(0.1)

# set all Igains to match those for this row
print 'setting I gains to match desired row'
Igains = zeros(n_cols,int)
for rc in range(0,n_rc):
    for col in range(0,MCE_COLS):
        Igains[rc*MCE_COLS+col] = m.read('rc%d'%(rc+1),'gaini%d'%(col))[row]
new_Igains = tile(Igains,(41,1))
for rc in range(0,n_rc):
    for col in range(0,MCE_COLS):
        m.write('rc%d'%(rc+1),'gaini%d'%col,new_Igains[:,rc*MCE_COLS+col].tolist())
        time.sleep(0.01)
time.sleep(0.1)
m.write('rca', 'flx_lp_init', [1])
time.sleep(0.1)


# CHOOSE LOOP CONFIGURATION
if opts.do_open:
    # go to open-loop mode
    print 'going to open-loop mode'
    # FIND FB1_CONST VALUES TO APPLY
    # read in a few frames of data in data_mode=1
    m.write('rca','data_mode',[1])
    m.write('rca','flx_lp_init',[1])
    time.sleep(1)
    if opts.do_direct_acq:
        # OLD CODE: Read the frames directly into Python
        print 'reading frames'
        frames = m.read_frames(opts.n_frames,data_only=True)
        time.sleep(1)
        # average all pixels over all frames
        print 'averaging frames'
        fb = fix(mean(array(frames),axis=0)/2**12).astype(int)
        # wrap into 14 bit signed range
        #fb = fb%2**14
        #for ii in range(0,len(fb)):
        #    if fb[ii]>(2**13-1):
        #        fb[ii] = fb[ii] - 2**14
    else:
        # ALTERNATE CODE: Make a file and read it in
        daqcmd = 'mce_fast_acq %d s 38 %d'%(opts.n_frames, n_rows)
        print daqcmd
        os.system(daqcmd)
        time.sleep(1)

        # what file did I take?
        datdir = '/data/cryo/current_data/'
        files = glob(os.path.join(datdir,'fast_??????????'))
        files.sort(lambda x,y:cmp(os.path.getmtime(x),
                                  os.path.getmtime(y)))
        fn = files[-1]

        # read the data in
        print 'load the new data file'
        f = SmallMCEFile(fn)
        d=f.Read()
        frames = d.data
        # average over all frames (CHECK THIS!!)
        fb = fix(mean(array(frames),axis=1)).astype(int)
	# fb = fix(mean(array(frames),axis=0)/2**12).astype(int)
    
    # In the future, mce will work directly with numpy arrays...
    fb = array(fb).reshape((n_rows,-1))
    # Find integer fb_const values to apply
    fb_const = fb[row,0:n_cols]
    print ('fb_const = ', fb_const)

    # FREEZE THE MCE ON THIS ROW WITH THESE FB1's
    # write the new fb_const vales
    m.write('sq1','fb_const',fb_const.tolist())
    # turn servo off
    m.write('rca','servo_mode',[0]*MCE_COLS)
    # read out error signal
    m.write('rca','data_mode',[0])
    m.write('rca','flx_lp_init',[1])
    time.sleep(1)
    print 'frozen in open-loop mode'
    print '(data_mode = 0)'

    # disable mux => BAD, do not do this!!
    #m.write('ac','enbl_mux',[0])
    #m.write('rca','flx_lp_init',[1])
    #time.sleep(0.2)
    #print 'MUX off'
else:
    # go to closed-loop mode
    print 'frozen in closed-loop mode'
    print '(data_mode unchanged)'