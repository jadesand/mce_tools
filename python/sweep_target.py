import numpy as np

import os
import sys
import time
from datetime import datetime
import subprocess

from mce_control import mce_control
import auto_setup as ast

_SAB = {
    'range': range(-100,100,10),
    'nframes': 1000,
    'card': 'sa',
    'param': 'bias',
}
_SAFB= {
    'range': range(-2500,2501,100),
    'nframes': 30,
    'card': 'sa',
    'param': 'fb',
}
_SQ1B= {
    'range': range(-100,100,10),
    'nframes': 1000,
    'card': 'sq1',
    'param': 'bias',
}
_SQ1FB= {
    'range': range(-2500,2501,250),
    'nframes': 30,
    'card': 'sq1',
    'param': 'fb_const',
}

MAS_DATA = os.environ.get('MAS_DATA')


USAGE="""
%prog [options] <sweep_target> <row>

Sweep the specified parameter for the specified row, and save the data to a file
in the current data directory with a name like 
"ramp_<timestamp>/openloop_ramp_<sweep_target>_r<row>.npy".

The "sweep_target" argument indicates which parameter to sweep, can be one of:
 - sab: SA bias
 - safb: SA feedback
 - sq1b: SQ1 bias
 - sq1fb: SQ1 feedback

The "row" argument indicates which row to read out for the data.  
"""

from optparse import OptionParser
o = OptionParser(usage=USAGE)
o.add_option('--config', default=None, type=str,
             help="tune config file.  If not provided, will use the default config file for the current setup.")
opts, args = o.parse_args()

SWEEP_TARGET = ['sab', 'safb', 'sq1b', 'sq1fb']

if args[0] not in SWEEP_TARGET:
    o.error("Provide the sweep type: (%s)." % ','.join(SWEEP_TARGET))


# Load config file
if opts.config is None:
    mas_path = ast.util.mas_path()
    exp_file = mas_path.experiment_file()
else:
    exp_file = opts.config
cfg = ast.config.configFile(exp_file)


target = args[0].lower()
row = None if len(args) == 1 else int(args[1])

ctime = int(time.mktime(datetime.now().timetuple()))
dirname = os.path.join(MAS_DATA, 'ramp_'+str(ctime))
if not os.path.exists(dirname):
    os.makedirs(dirname)

mce = mce_control()


target_dict = eval('_'+args[0].upper())
nframes = target_dict['nframes']
sweep_range = np.array(target_dict['range'])
card = target_dict['card']
param = target_dict['param']
print '{}={}'.format(args[0].lower(), sweep_range)

fname_x = os.path.join(dirname, 'openloop_ramp_%s'%(target))

fname_ymed = os.path.join(dirname, 'openloop_ramp_data_med')
fname_ystd = os.path.join(dirname, 'openloop_ramp_data_std')

### Freeze servo
freeze_cmd = ['python', 'mce_freeze_servo_mux11d.py', card]
if row is not None:
    freeze_cmd += ['--row', str(row)]
subprocess.call(freeze_cmd)

orig = subprocess.Popen(["mce_cmd","-x","rb",card,param],stdout=subprocess.PIPE).communicate()[0].strip()
orig = np.array([int(ob) for ob in subprocess.Popen(["mce_cmd","-x","rb",card,param],stdout=subprocess.PIPE).communicate()[0].strip().split('\n')[1].split(':')[2].split()],'int')
print 'orig_%s_%s='%(card, param), orig
np.save(fname_x, np.array(orig[:, None]+sweep_range[None, :]))

columns_off = np.array(cfg['columns_off'][:len(orig)])
print 'columns_off=',columns_off

ncol = len(orig)
ymed = []
ystd = []
for swp in sweep_range:

    new = orig + np.array([swp]*ncol)

    # make sure we don't sweep sab on columns in columns off
    new[np.where(columns_off==1)]=0

    print 'new_%s_%s='%(card, param), new
    mce.write(card, param, new)
    time.sleep(0.1) # let settle

    # 0 in [0,:,:]=row, which shouldn't matter for this data
    data = mce.read_data(nframes, row_col=True).data
    med, std = data.mean(axis=-1), data.std(axis=-1)
    ymed.append(med)
    ystd.append(std)
np.save(fname_ymed, np.array(ymed))
np.save(fname_ystd, np.array(ystd)) 

print 'Done. Data saved to %s'%dirname

# mce.write(card, param, orig)
print 'reconfig...'
# Partial reconfig (does not fully restore MCE state for consecutive runs):
# subprocess.call(['mce_zero_bias'], stdout=open(os.devnull, 'w'))
# time.sleep(1)
# subprocess.call(['mce_make_config', '-x', '-e', exp_file], stdout=open(os.devnull, 'w'))
# mce.servo_mode(3)
subprocess.call(['mce_reconfig'])