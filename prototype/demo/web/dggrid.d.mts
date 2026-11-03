// TypeScript declarations for dggrid.mjs (copied from ../../wasm/dggrid.mjs by copy_libs.sh)

export declare const PRESET: Readonly<{ IGEO7v2: 0; IGEO7v1: 1; IVEA7HL: 2; IVEA7HS: 3 }>;
export type Preset = (typeof PRESET)[keyof typeof PRESET];

export declare const WRAP: Readonly<{ NONE: 0; EAST: 1; WEST: 2 }>;
export type Wrap = (typeof WRAP)[keyof typeof WRAP];

/** Z7 cell index; plain numbers lose bits beyond 2^53, use bigint */
export type Z7 = bigint;
export type Lon = ArrayLike<number>;
export type Ring = [lon: number, lat: number][];

export interface ArrowIds {
  format: string; // 'L' = uint64
  name: string; // 'z7'
  metadata: Record<string, string>;
  length: number;
  nullCount: number;
  nullBitmap: Uint8Array | null; // Arrow validity bitmap, bit set = valid
  values: BigUint64Array;
}

export interface ArrowPolygons {
  format: string;
  name: string;
  /** 'ARROW:extension:name' = 'geoarrow.polygon', 'ARROW:extension:metadata' = CRS json */
  metadata: Record<string, string>;
  length: number;
  nullCount: number;
  polygons: Int32Array; // offsets into rings, length + 1
  rings: Int32Array; // offsets into x / y, closed rings
  x: Float64Array;
  y: Float64Array;
}

export interface LoadOptions {
  preset?: Preset;
  /** DGGRID stdout (fd 1) / stderr (fd 2) */
  log?: (fd: number, text: string) => void;
}

export declare class Igeo7 {
  /** instantiate dggrid.wasm (bytes or a fetch Response) with a context for one preset */
  static load(source: BufferSource | Response, options?: LoadOptions): Promise<Igeo7>;
  free(): void;
  /** polygon longitudes across the antimeridian, default WRAP.EAST */
  setLonWrap(mode: Wrap): void;
  /** points (degrees) -> cells at resolution res (0..20) */
  geoToZ7(res: number, lon: Lon, lat: Lon): BigUint64Array;
  z7ToCentroid(ids: ArrayLike<Z7> | Z7[]): { lon: Float64Array; lat: Float64Array };
  /** lonlat: 6 pairs per cell, NaN padded; nverts 6, or 5 for pentagons */
  z7ToBoundaryRaw(ids: ArrayLike<Z7> | Z7[]): { lonlat: Float64Array; nverts: Uint8Array };
  /** open rings of [lon, lat] */
  z7ToBoundary(ids: ArrayLike<Z7> | Z7[]): Ring[];
  /** NaN, NaN = null */
  lonLatToZ7Arrow(res: number, lon: Lon, lat: Lon): ArrowIds;
  z7ToPolygonsArrow(ids: ArrayLike<Z7> | Z7[]): ArrowPolygons;
  /** -1 if invalid */
  z7Res(id: Z7): number;
  z7ToString(id: Z7): string;
  z7FromString(s: string): Z7;
}
