CREATE TABLE IF NOT EXISTS readings (
  timestamp INTEGER PRIMARY KEY NOT NULL,
  collected_at INTEGER NOT NULL,
  soc REAL,
  soh REAL,
  pv_kw REAL,
  load_kw REAL,
  grid_import_kw REAL,
  grid_export_kw REAL,
  charge_kw REAL,
  discharge_kw REAL,
  stored_kwh REAL,
  capacity_kwh REAL NOT NULL DEFAULT 41.93,
  generation_kwh REAL,
  load_kwh REAL,
  grid_import_kwh REAL,
  grid_export_kwh REAL,
  charge_total_kwh REAL,
  discharge_total_kwh REAL,
  pv_total_kwh REAL
);

CREATE INDEX IF NOT EXISTS idx_readings_timestamp ON readings(timestamp DESC);

CREATE TABLE IF NOT EXISTS amber_prices (
  start_time INTEGER NOT NULL,
  end_time INTEGER NOT NULL,
  channel_type TEXT NOT NULL,
  per_kwh REAL,
  spot_per_kwh REAL,
  interval_type TEXT NOT NULL,
  descriptor TEXT,
  estimate INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(start_time, channel_type)
);

CREATE INDEX IF NOT EXISTS idx_amber_prices_time ON amber_prices(start_time DESC);
