"""
DAC-to-current calibration estimator.

Runs measure_quanta.py on sq1_ramp and sq1_ramp_tes tuning data for a set of
channels, takes the median flux-quantum period (in DAC units) across those
channels for each stage, and converts to current calibrations using the
known SQUID/TES mutual inductances and the magnetic flux quantum.

    tesb_dac_to_uA      = flux_quantum_Wb / M_SQ1IN_pH / tes_quantum_dac
    sq1fb_dac_to_uA     = flux_quantum_Wb / M_SQ1FB_pH / sq1fb_quantum_dac
    sq1fb_dac_to_tes_uA = sq1fb_dac_to_uA * (M_SQ1FB_pH / M_SQ1IN_pH)
"""
import os
import re
import subprocess
import sys

FLUX_QUANTUM_WB = 2.067833848e-15  # magnetic flux quantum h/2e, in Wb

STAGE_VARNAME = {
    'sq1_ramp': 'flux_quanta_all',
    'sq1_ramp_tes': 'tes_quanta',
}


def run_measure_quanta(tuning_dir, stage):
    """Run measure_quanta.py for the given tuning_dir/stage and return stdout."""
    mas_python = os.environ['MAS_PYTHON']
    script = os.path.join(mas_python, 'measure_quanta.py')
    out = subprocess.check_output(['python', script, tuning_dir, stage])
    return out


def parse_quanta_array(text, varname):
    """Parse the 'varname = [ ... ];' array printed by measure_quanta.py.

    Returns a dict mapping (row, col) -> quantum value.
    """
    m = re.search(varname + r'\s*=\s*\[(.*?)\];', text, re.DOTALL)
    if m is None:
        raise ValueError("Could not find '%s' array in measure_quanta.py output:\n%s"
                          % (varname, text))
    data = {}
    for line in m.group(1).strip().split('\n'):
        line = line.strip().rstrip(',')
        if not line:
            continue
        cm = re.match(r'/\*\s*c(\d+)\s*\*/\s*(.*)', line)
        if cm is None:
            continue
        col = int(cm.group(1))
        vals = [int(x.strip()) for x in cm.group(2).split(',') if x.strip() != '']
        for row, v in enumerate(vals):
            data[(row, col)] = v
    return data


def parse_channel(ch):
    """Parse a 'rXXcXX' channel string into (row, col)."""
    cm = re.match(r'r(\d+)c(\d+)$', ch.strip())
    if cm is None:
        raise ValueError("Could not parse channel '%s' (expected rXXcXX)" % ch)
    return int(cm.group(1)), int(cm.group(2))


def select_quanta(data, channels):
    """Pick quantum values for the given channels, skipping zero/missing ones."""
    vals = []
    for ch in channels:
        row, col = parse_channel(ch)
        v = data.get((row, col))
        if v is None:
            print("Warning: channel %s not found in quanta data, skipping" % ch)
            continue
        if v == 0:
            print("Warning: channel %s has zero quantum (likely bad/masked), skipping" % ch)
            continue
        vals.append(v)
    return vals


def median(vals):
    s = sorted(vals)
    n = len(s)
    if n % 2 == 1:
        return float(s[n // 2])
    return (s[n // 2 - 1] + s[n // 2]) / 2.0


def estimate_calibration(channels, sq1_ramp_dir, sq1_ramp_tes_dir,
                          m_sq1in_ph=683.3, m_sq1fb_ph=29.0):
    """
    Compute tesb_dac_to_uA, sq1fb_dac_to_uA, sq1fb_dac_to_tes_uA for the given
    channels and tune directories.

    Returns a dict with keys: tesb_dac_to_uA, sq1fb_dac_to_uA,
    sq1fb_dac_to_tes_uA, sq1fb_quantum_dac, tes_quantum_dac.
    """
    print("Running measure_quanta.py for sq1_ramp (%s)..." % sq1_ramp_dir)
    sq1_ramp_out = run_measure_quanta(sq1_ramp_dir, 'sq1_ramp')

    print("Running measure_quanta.py for sq1_ramp_tes (%s)..." % sq1_ramp_tes_dir)
    sq1_ramp_tes_out = run_measure_quanta(sq1_ramp_tes_dir, 'sq1_ramp_tes')

    sq1fb_data = parse_quanta_array(sq1_ramp_out, STAGE_VARNAME['sq1_ramp'])
    tes_data = parse_quanta_array(sq1_ramp_tes_out, STAGE_VARNAME['sq1_ramp_tes'])

    sq1fb_vals = select_quanta(sq1fb_data, channels)
    tes_vals = select_quanta(tes_data, channels)

    if len(sq1fb_vals) == 0:
        raise ValueError("no valid sq1_ramp quanta found for given channels")
    if len(tes_vals) == 0:
        raise ValueError("no valid sq1_ramp_tes quanta found for given channels")

    sq1fb_quantum_dac = median(sq1fb_vals)
    tes_quantum_dac = median(tes_vals)

    print("sq1fb_quantum_dac (median, n=%d): %g" % (len(sq1fb_vals), sq1fb_quantum_dac))
    print("tes_quantum_dac (median, n=%d): %g" % (len(tes_vals), tes_quantum_dac))

    tesb_dac_to_uA = FLUX_QUANTUM_WB / (m_sq1in_ph * 1e-12) / tes_quantum_dac * 1e6
    sq1fb_dac_to_uA = FLUX_QUANTUM_WB / (m_sq1fb_ph * 1e-12) / sq1fb_quantum_dac * 1e6
    sq1fb_dac_to_tes_uA = sq1fb_dac_to_uA / (m_sq1fb_ph / m_sq1in_ph)

    return {
        'sq1fb_quantum_dac': sq1fb_quantum_dac,
        'tes_quantum_dac': tes_quantum_dac,
        'tesb_dac_to_uA': tesb_dac_to_uA,
        'sq1fb_dac_to_uA': sq1fb_dac_to_uA,
        'sq1fb_dac_to_tes_uA': sq1fb_dac_to_tes_uA,
    }


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Estimate DAC-to-current calibration from sq1_ramp and "
                     "sq1_ramp_tes tuning data."
    )
    parser.add_argument("-c", "--channels", nargs='+', required=True,
                         help="channels to use, as rxxcxx (space-separated)")
    parser.add_argument("-t", "--sq1-ramp-dir", required=True,
                         help="path to the tuning directory for sq1_ramp stage")
    parser.add_argument("-T", "--sq1-ramp-tes-dir", default=None,
                         help="path to the tuning directory for sq1_ramp_tes stage "
                              "(default: same as --sq1-ramp-dir)")
    parser.add_argument("--m-sq1in-ph", type=float, default=683.3,
                         help="M_SQ1IN mutual inductance in pH (default: 683.3)")
    parser.add_argument("--m-sq1fb-ph", type=float, default=29.0,
                         help="M_SQ1FB mutual inductance in pH (default: 29)")
    args = parser.parse_args()

    sq1_ramp_tes_dir = args.sq1_ramp_tes_dir or args.sq1_ramp_dir

    result = estimate_calibration(
        args.channels, args.sq1_ramp_dir, sq1_ramp_tes_dir,
        args.m_sq1in_ph, args.m_sq1fb_ph)

    print("")
    print("tesb_dac_to_uA = %g" % result['tesb_dac_to_uA'])
    print("sq1fb_dac_to_uA = %g" % result['sq1fb_dac_to_uA'])
    print("sq1fb_dac_to_tes_uA = %g" % result['sq1fb_dac_to_tes_uA'])
