#!/usr/bin/env python

import os,sys
import argparse
import time

import numpy as np
#import pylab as pl

from pymce import MCE

DEBUG = False

class MCEWrap():
	def __init__(self):
		self.m = MCE()
	def read(self,x,y):
		v = self.m.read(x,y)
		print "rb %s %s = %s"%(x,y,str(v))
		return v
	def write(self,x,y,v):
		print "wb %s %s %s"%(x,y,str(v))
		if not DEBUG:
			self.m.write(x,y,v)

def main():
	parser = argparse.ArgumentParser()
	parser.add_argument('-d','--dataname',required=True)
	parser.add_argument('-c','--columns',type=int,nargs='+')
	parser.add_argument('--bias_start',type=int,default=2000)
	parser.add_argument('--bias_step',type=int,default=-2)
	parser.add_argument('--bias_count',type=int,default=1001)
	parser.add_argument('--zap_bias',type=int,default=30000)
	parser.add_argument('--zap_time',type=float,default=1.0)
	parser.add_argument('--settle_time',type=float,default=10.0)
	parser.add_argument('--settle_bias',type=float,default=2000.)
	parser.add_argument('--bias_pause',type=float,default=0.1)
	parser.add_argument('--bias_final',type=int,default=0)
	parser.add_argument('--data_mode',type=int,default=1)
	args = parser.parse_args()


	data_name = args.dataname
	bias_cols = args.columns

	bias_start = args.bias_start
	bias_step = args.bias_step
	bias_count = args.bias_count
	zap_bias = args.zap_bias
	zap_time = args.zap_time
	settle_time = args.settle_time
	settle_bias = args.settle_bias
	bias_pause = args.bias_pause
	bias_final = args.bias_final
	data_mode = args.data_mode

	#m = MCE()
	m = MCEWrap()

	mas_data = os.environ['MAS_DATA']
	dname = os.path.join(mas_data,data_name)
	fname = os.path.join(dname,data_name)
	if not os.path.exists(dname):
		os.mkdir(dname)
		print "created directory "+dname
	else:
		print "directory already exists, aborting"
		exit(1)

	flog = os.path.join(dname,'lc_ramp_tes_bias_log.txt')
	print "logging ramp parameters to "+flog
	f = open(flog,'w')
	print>>f,"Parameters for this run"
	print>>f,"bias_start=",bias_start
	print>>f,"bias_step=",bias_step
	print>>f,"bias_count=",bias_count
	print>>f,"zap_bias=",zap_bias
	print>>f,"zap_time=",zap_time
	print>>f,"settle_time=",settle_time
	print>>f,"bias_pause=",bias_pause
	print>>f,"bias_final=",bias_final
	print>>f,"data_mode=",data_mode
	f.close()

	print "Setting up MCE mode"
	m.write('rca','data_mode',data_mode)
	m.write('rca','en_fb_jump',1)
	m.write('rca','flx_lp_init',1)

	ncol = len(m.read('tes','bias'))
	if bias_cols is None:
		bias_cols = np.arange(ncol)

	bias_mask = np.zeros(ncol,dtype=np.int32)
	for c in bias_cols:
		bias_mask[c] = 1
	
	runfile = fname + '.run'
	biasfile = fname + '.bias'
	logfile = fname + '.log'
	
  	os.system('mce_status > '+runfile)
	os.system('frameacq_stamp %s %s %d >> %s'%('s',fname,bias_count,runfile))
	biasf = open(biasfile,'w')
	print>>biasf,"<tes_bias>"

	print "zapping"
	zap_arr = bias_mask * zap_bias
	bias_start_arr = bias_mask * bias_start
	m.write('tes','bias',zap_arr)
	time.sleep(zap_time)
	print "settling"
	m.write('tes','bias',bias_mask*settle_bias)
	time.sleep(settle_time)


	m.write('tes','bias',bias_mask*bias_start)
	time.sleep(0.1)
	m.write('rca','flx_lp_init',1)
	time.sleep(0.1)

	bscript = os.path.join(dname,'bias_script.scr')
	b = open(bscript,'w')
	print>>b,'acq_config %s rcs'%fname
	for i in range(bias_count):
		bias = bias_step*i + bias_start
		print>>biasf,bias
		bias_str = ' '.join([str(x) for x in bias*bias_mask])
		print>>b,'wb tes bias '+bias_str
		print>>b,'sleep %d'%(bias_pause*1e6)
		print>>b,'acq_go 1'

	biasf.close()
	b.close()
	t0 = time.time()
	print "executing bias ramp"
	if not DEBUG:
		os.system('mce_cmd -qf '+bscript)
	t1 = time.time()
	print "ramp finished in %.2f seconds"%(t1-t0)

	m.write('tes','bias',bias_mask*bias_final)
	m.write('rca','flx_lp_init',1)

	

if __name__=='__main__':
	main()

