// Reference runner for the JS prototype, same output format as
// gate-fall-game/tools/run_sims.gd so the two can be diffed.
//   node prototype/run_sims.js [--runs=300] [--seed=1] [--per-battle]
// Uses battle_core.js unchanged; the loop mirrors simulate() exactly.
const core = require('./battle_core.js');

const opts = {};
for (const a of process.argv.slice(2)) {
  if (!a.startsWith('--')) continue;
  const [k, v] = a.slice(2).split('=');
  opts[k] = v === undefined ? true : v;
}
const runs = +(opts.runs || 300), seed = +(opts.seed || 1), perBattle = !!opts['per-battle'];

console.log(`Prototype battle sims: ${runs} runs/combo, seed ${seed}, player side S vs K`);
console.log('formation order   special     win%    time  surv(win) enemy(loss)');
const t0 = Date.now();
for (const form of ['line', 'wedge', 'square', 'crescent'])
  for (const mode of ['charge', 'hold'])
    for (const auto of [false, true]) {
      const cfg = core.makeCfg({ form, mode, auto });
      let s = seed; const rng = () => ((s = (s * 16807) % 2147483647) / 2147483647);
      let win = 0, time = 0, surv = 0, sk = 0;
      for (let i = 0; i < runs; i++) {
        const B = core.newBattle(cfg, rng);
        while (!B.over) { core.step(B, 1 / 15); B.events.length = 0; }
        const c = core.count(B);
        if (B.over === 'S') { win++; surv += c.big + c.mini; } else sk += c.k;
        time += B.time;
        if (perBattle) console.log(`B ${form} ${mode} ${+auto} ${i} ${B.over} ${c.big + c.mini} ${c.k} ${B.time.toFixed(6)}`);
      }
      const r = { win: win / runs, time: time / runs, survS: win ? surv / win : 0, survK: runs - win ? sk / (runs - win) : 0 };
      console.log(`${form.padEnd(9)} ${mode.padEnd(7)} ${(auto ? 'on' : 'off').padEnd(8)} ${(r.win * 100).toFixed(1).padStart(6)}% ${r.time.toFixed(1).padStart(6)}s ${r.survS.toFixed(2).padStart(10)} ${r.survK.toFixed(2).padStart(10)}`);
    }
console.log(`done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
