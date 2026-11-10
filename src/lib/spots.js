import { supabase } from './supabase'
import { mockSpots } from './mockSpots'

/** 取得視窗內餵食點。有 Supabase 設定走 RPC，否則假資料。 */
export async function fetchMapSpots(bounds) {
  if (!supabase) return mockSpots
  const { data, error } = await supabase.rpc('get_map_spots', {
    min_lng: bounds.getWest(),
    min_lat: bounds.getSouth(),
    max_lng: bounds.getEast(),
    max_lat: bounds.getNorth(),
  })
  if (error) throw error
  return data
}
