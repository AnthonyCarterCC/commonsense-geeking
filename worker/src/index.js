const FOX_BASE = "https://www.foxesscloud.com";
const HISTORY_PATH = "/op/v0/device/history/query";
const VARIABLES = [
  "SoC", "SOH", "pvPower", "generationPower", "loadsPower", "gridConsumptionPower", "feedinPower",
  "batChargePower", "batDischargePower", "ResidualEnergy", "generation", "loads",
  "gridConsumption", "feedin", "chargeEnergyToTal", "dischargeEnergyToTal", "PVEnergyTotal"
];

const corsHeaders = (env) => ({
  "Access-Control-Allow-Origin": env.ALLOWED_ORIGIN || "https://geeking.commonsense.com.au",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Cache-Control": "no-store",
  "Vary": "Origin"
});

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const headers = corsHeaders(env);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
    if (request.method !== "GET") return json({ error: "Method not allowed" }, 405, headers);
    if (url.pathname === "/api/health") {
      const row = await env.DB.prepare("SELECT MAX(timestamp) AS latest FROM readings").first();
      return json({ configured: Boolean(env.FOXESS_TOKEN && env.FOXESS_DEVICE_SN), amberConfigured: Boolean(env.AMBER_TOKEN), latest: row?.latest ?? null }, 200, headers);
    }
    if (url.pathname === "/api/prices") {
      const hours = Math.max(1, Math.min(24 * 7, Number.parseInt(url.searchParams.get("hours") || "24", 10) || 24));
      const since = Date.now() - 60 * 60 * 1000;
      const until = Date.now() + hours * 60 * 60 * 1000;
      const result = await env.DB.prepare(
        `SELECT start_time AS startTime, end_time AS endTime, per_kwh AS perKwh,
          spot_per_kwh AS spotPerKwh, interval_type AS type, descriptor, estimate
         FROM amber_prices WHERE end_time > ? AND start_time < ? ORDER BY start_time ASC LIMIT 1000`
      ).bind(since, until).all();
      return json({ prices: result.results || [] }, 200, headers);
    }
    if (url.pathname !== "/api/readings") return json({ error: "Not found" }, 404, headers);

    const hours = Math.max(1, Math.min(24 * 30, Number.parseInt(url.searchParams.get("hours") || "24", 10) || 24));
    const since = Date.now() - hours * 60 * 60 * 1000;
    const result = await env.DB.prepare(
      `SELECT timestamp, soc, soh, pv_kw AS pvKw, load_kw AS loadKw,
        grid_import_kw AS gridImportKw, grid_export_kw AS gridExportKw,
        charge_kw AS chargeKw, discharge_kw AS dischargeKw,
        stored_kwh AS storedKwh, capacity_kwh AS capacityKwh,
        generation_kwh AS generationKwh, load_kwh AS loadKwh,
        grid_import_kwh AS gridImportKwh, grid_export_kwh AS gridExportKwh,
        charge_total_kwh AS chargeTotalKwh, discharge_total_kwh AS dischargeTotalKwh,
        pv_total_kwh AS pvTotalKwh
       FROM readings WHERE timestamp >= ? ORDER BY timestamp DESC LIMIT 10000`
    ).bind(since).all();
    return json({ readings: result.results || [] }, 200, headers);
  },

  async scheduled(_event, env, ctx) {
    ctx.waitUntil(collectHourly(env));
  }
};

async function collectHourly(env) {
  if (!env.DB || !env.FOXESS_TOKEN || !env.FOXESS_DEVICE_SN) {
    throw new Error("Configure D1, FOXESS_TOKEN and FOXESS_DEVICE_SN before enabling the hourly collector.");
  }

  const capacityKwh = finite(env.BATTERY_CAPACITY_KWH, 41.93);
  const end = Date.now();
  const begin = end - 60 * 60 * 1000;
  const body = {
    sn: env.FOXESS_DEVICE_SN,
    variables: VARIABLES,
    begin,
    end
  };
  const response = await foxRequest(env.FOXESS_TOKEN, HISTORY_PATH, body);
  const payload = await response.json();
  if (!response.ok || payload.errno !== 0) {
    throw new Error(`FoxESS history request failed (HTTP ${response.status}, errno ${payload.errno ?? "unknown"}).`);
  }

  const device = Array.isArray(payload.result)
    ? payload.result.find((item) => item.deviceSN === env.FOXESS_DEVICE_SN) || payload.result[0]
    : payload.result;
  const points = pointsFrom(device, capacityKwh); await new Promise((resolve) => setTimeout(resolve, 1100)); await new Promise((resolve) => setTimeout(resolve, 1100)); try { const livePoint = await queryFoxLivePoint(env.FOXESS_TOKEN, env.FOXESS_DEVICE_SN, capacityKwh); if (livePoint) points.push(livePoint); } catch (error) { console.warn("FoxESS inverter live query failed", String(error)); }
  if (!points.length) throw new Error("FoxESS returned no history points for the previous hour.");

  const statements = points.map((point) => env.DB.prepare(
    `INSERT INTO readings (
      timestamp, collected_at, soc, soh, pv_kw, load_kw, grid_import_kw, grid_export_kw,
      charge_kw, discharge_kw, stored_kwh, capacity_kwh, generation_kwh, load_kwh,
      grid_import_kwh, grid_export_kwh, charge_total_kwh, discharge_total_kwh, pv_total_kwh
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(timestamp) DO UPDATE SET
      collected_at=excluded.collected_at, soc=excluded.soc, soh=excluded.soh,
      pv_kw=excluded.pv_kw, load_kw=excluded.load_kw,
      grid_import_kw=excluded.grid_import_kw, grid_export_kw=excluded.grid_export_kw,
      charge_kw=excluded.charge_kw, discharge_kw=excluded.discharge_kw,
      stored_kwh=excluded.stored_kwh, capacity_kwh=excluded.capacity_kwh,
      generation_kwh=excluded.generation_kwh, load_kwh=excluded.load_kwh,
      grid_import_kwh=excluded.grid_import_kwh, grid_export_kwh=excluded.grid_export_kwh,
      charge_total_kwh=excluded.charge_total_kwh, discharge_total_kwh=excluded.discharge_total_kwh,
      pv_total_kwh=excluded.pv_total_kwh`
  ).bind(
    point.timestamp, end, point.soc, point.soh, point.pvKw, point.loadKw,
    point.gridImportKw, point.gridExportKw, point.chargeKw, point.dischargeKw,
    point.storedKwh, capacityKwh, point.generationKwh, point.loadKwh,
    point.gridImportKwh, point.gridExportKwh, point.chargeTotalKwh,
    point.dischargeTotalKwh, point.pvTotalKwh
  ));
  statements.push(env.DB.prepare("DELETE FROM readings WHERE timestamp < ?").bind(end - 5 * 366 * 24 * 60 * 60 * 1000));
  await env.DB.batch(statements);

  if (env.AMBER_TOKEN) {
    const prices = await collectAmberPrices(env);
    const priceStatements = [];
    for (const price of prices) {
      priceStatements.push(env.DB.prepare(
        `INSERT INTO amber_prices(start_time, end_time, channel_type, per_kwh, spot_per_kwh, interval_type, descriptor, estimate)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(start_time, channel_type) DO UPDATE SET
           end_time=excluded.end_time, per_kwh=excluded.per_kwh,
           spot_per_kwh=excluded.spot_per_kwh, interval_type=excluded.interval_type,
           descriptor=excluded.descriptor, estimate=excluded.estimate`
      ).bind(price.startTime, price.endTime, price.channelType, price.perKwh, price.spotPerKwh,
        price.type, price.descriptor, price.estimate ? 1 : 0));
    }
    priceStatements.push(env.DB.prepare("DELETE FROM amber_prices WHERE start_time < ?").bind(end - 5 * 366 * 24 * 60 * 60 * 1000));
    if (priceStatements.length) await env.DB.batch(priceStatements);
  }
}

async function firstAmberSite(token) { const response = await fetch("https://api.amber.com.au/v1/sites", { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } }); if (!response.ok) throw new Error(`Amber site lookup failed (HTTP ${response.status}).`); const sites = await response.json(); const site = Array.isArray(sites) ? sites.find((item) => item.status === "active") || sites[0] : null; if (!site?.id) throw new Error("Amber API returned no sites for this token."); return site.id; } async function collectAmberPrices(env) {
  const siteId = env.AMBER_SITE_ID || await firstAmberSite(env.AMBER_TOKEN); const url = new URL(`https://api.amber.com.au/v1/sites/${encodeURIComponent(siteId)}/prices/current`);
  url.searchParams.set("next", "48");
  url.searchParams.set("previous", "2");
  url.searchParams.set("resolution", "30");
  const response = await fetch(url, { headers: { Authorization: `Bearer ${env.AMBER_TOKEN}`, Accept: "application/json" } });
  if (!response.ok) throw new Error(`Amber prices request failed (HTTP ${response.status}).`);
  const body = await response.json();
  if (!Array.isArray(body)) throw new Error("Amber prices response was not an array.");
  return body.filter((row) => row.channelType === "general" && row.startTime && row.endTime)
    .map((row) => ({
      startTime: Date.parse(row.startTime),
      endTime: Date.parse(row.endTime),
      channelType: row.channelType,
      perKwh: finite(row.perKwh),
      spotPerKwh: finite(row.spotPerKwh),
      type: row.type || "unknown",
      descriptor: row.descriptor || null,
      estimate: Boolean(row.estimate)
    }))
    .filter((row) => Number.isFinite(row.startTime) && Number.isFinite(row.endTime));
}

async function foxRequest(token, path, body) {
  const timestamp = String(Date.now());
  const signature = await md5(`${path}\r\n${token}\r\n${timestamp}`);
  return fetch(`${FOX_BASE}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      token,
      timestamp,
      signature,
      lang: "en",
      "User-Agent": "CommonsenseGeekingSolarMonitor/1.0"
    },
    body: JSON.stringify(body)
  });
}

async function queryFoxLivePoint(token, deviceSN, capacityKwh) { const path = "/op/v1/device/real/query"; const variables = ["SoC", "SOH", "generationPower", "pvPower", "loadsPower", "gridConsumptionPower", "feedinPower", "batChargePower", "batDischargePower", "ResidualEnergy"]; const response = await foxRequest(token, path, { sns: [deviceSN] }); if (!response.ok) return null; const payload = await response.json(); if (payload.errno !== 0) return null; const device = Array.isArray(payload.result) ? payload.result.find((item) => item.deviceSN === deviceSN) || payload.result[0] : payload.result; const values = Object.fromEntries((device?.datas || []).map((item) => [item.variable, finite(item.value)])); const timestamp = parseFoxTime(device?.time || device?.datas?.find((item) => item.time)?.time) || Date.now(); if (!Object.keys(values).length) return null; console.info("FOXESS_LIVE_DIAGNOSTIC", JSON.stringify(Object.fromEntries(["SoC", "SOH", "pvPower", "generationPower", "loadsPower", "gridConsumptionPower", "feedinPower", "batChargePower", "batDischargePower", "ResidualEnergy", "meterPower", "PVEnergyTotal"].map((key) => [key, values[key] ?? null])))); return { timestamp, soc: values.SoC, soh: values.SOH, pvKw: values.generationPower ?? values.pvPower, loadKw: values.loadsPower, gridImportKw: values.gridConsumptionPower, gridExportKw: values.feedinPower, chargeKw: values.batChargePower, dischargeKw: values.batDischargePower, storedKwh: values.ResidualEnergy ?? (values.SoC == null ? null : capacityKwh * values.SoC / 100), generationKwh: null, loadKwh: null, gridImportKwh: null, gridExportKwh: null, chargeTotalKwh: null, dischargeTotalKwh: null, pvTotalKwh: null }; } function pointsFrom(device, capacityKwh) {
  const byTime = new Map();
  for (const series of device?.datas || []) {
    const name = series.variable;
    for (const sample of (series.data || [])) {
      const timestamp = parseFoxTime(sample.time);
      if (!timestamp) continue;
      if (!byTime.has(timestamp)) byTime.set(timestamp, {});
      byTime.get(timestamp)[name] = finite(sample.value, null);
    }
  }
  return [...byTime.entries()].sort(([a], [b]) => a - b).map(([timestamp, v]) => ({
    timestamp,
    soc: v.SoC,
    soh: v.SOH,
    pvKw: v.generationPower ?? v.pvPower,
    loadKw: v.loadsPower,
    gridImportKw: v.gridConsumptionPower,
    gridExportKw: v.feedinPower,
    chargeKw: v.batChargePower,
    dischargeKw: v.batDischargePower,
    storedKwh: v.ResidualEnergy ?? (v.SoC == null ? null : capacityKwh * v.SoC / 100),
    generationKwh: v.generation,
    loadKwh: v.loads,
    gridImportKwh: v.gridConsumption,
    gridExportKwh: v.feedin,
    chargeTotalKwh: v.chargeEnergyToTal,
    dischargeTotalKwh: v.dischargeEnergyToTal,
    pvTotalKwh: v.PVEnergyTotal
  }));
}

function parseFoxTime(value) {
  if (!value) return null;
  let epoch = Date.parse(value);
  if (!Number.isFinite(epoch)) {
    const normalized = String(value).replace(/\s+[A-Z]{2,6}([+-]\d{2})(\d{2})$/, "$1:$2");
    epoch = Date.parse(normalized);
  }
  return Number.isFinite(epoch) ? epoch : null;
}

function finite(value, fallback = null) {
  if (value === null || value === undefined || value === "") return fallback;
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

async function md5(text) {
  const shifts = [7,12,17,22, 5,9,14,20, 4,11,16,23, 6,10,15,21];
  const constants = Array.from({ length: 64 }, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0);
  const bytes = new TextEncoder().encode(text);
  const bitLength = bytes.length * 8;
  const size = ((bytes.length + 8) >>> 6) + 1;
  const padded = new Uint8Array(size * 64);
  padded.set(bytes); padded[bytes.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, bitLength >>> 0, true);
  view.setUint32(padded.length - 4, Math.floor(bitLength / 2 ** 32), true);
  let a0=0x67452301, b0=0xefcdab89, c0=0x98badcfe, d0=0x10325476;
  for (let offset=0; offset<padded.length; offset+=64) {
    const words=Array.from({length:16},(_,i)=>view.getUint32(offset+i*4,true));
    let a=a0,b=b0,c=c0,d=d0;
    for(let i=0;i<64;i++){
      let f,g,s;
      if(i<16){f=(b&c)|(~b&d);g=i;s=shifts[i%4]}
      else if(i<32){f=(d&b)|(~d&c);g=(5*i+1)%16;s=shifts[4+i%4]}
      else if(i<48){f=b^c^d;g=(3*i+5)%16;s=shifts[8+i%4]}
      else{f=c^(b|~d);g=(7*i)%16;s=shifts[12+i%4]}
      const sum=(a+f+constants[i]+words[g])>>>0;
      const rotated=(sum<<s)|(sum>>>(32-s));
      const next=(b+rotated)>>>0;
      a=d;d=c;c=b;b=next;
    }
    a0=(a0+a)>>>0;b0=(b0+b)>>>0;c0=(c0+c)>>>0;d0=(d0+d)>>>0;
  }
  const out=new Uint8Array(16);const outView=new DataView(out.buffer);
  [a0,b0,c0,d0].forEach((v,i)=>outView.setUint32(i*4,v,true));
  return [...out].map((b)=>b.toString(16).padStart(2,"0")).join("");
}

function json(body, status, headers) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, "Content-Type": "application/json; charset=utf-8" }
  });
}
