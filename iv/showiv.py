#!/usr/bin/env python
import os
import sys

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

import mce_data

def get_color(s):
  c = plt.get_cmap('hot')

def main():
  folder = sys.argv[1]
  name = os.path.split(folder)[1]
  fn = os.path.join(folder,name)

  biasfn = fn + '.bias'
  f = mce_data.MCEFile(fn)
  dname = os.path.split(fn)[0]
  bias = np.loadtxt(biasfn,skiprows=1)
  y = -1.0*f.Read(row_col=True,unfilter='DC').data  
  
  nr,nc,nt = y.shape
  print(nc)
  print(nr)
  rows = np.zeros((16,41),dtype=np.int)
  cols = np.zeros((16,41),dtype=np.int)

  for col in [0, 1, 2, 3, 4, 6, 7, 11, 12, 14, 15]:
    print col,
    for row in range(0, 41):
      sys.stdout.flush()
      plt.clf()
      plt.title('Column %02d'%col)
      #for row in range(22,33):
      plt.plot(bias,y[row,col])
      
      fn_s = os.path.join(dname,'iv_col%02d_row%02d.png'%(col,row))
      #plt.ylim(-20000,45000)
      #plt.ylim(2900, 3100)
      plt.xlabel('Bias Current (arbitrary units)')
      plt.ylabel('SQ1FB (arbitrary units)')
      plt.grid()
      plt.savefig(fn_s)
      
  print ''

if __name__=='__main__':
  main()
