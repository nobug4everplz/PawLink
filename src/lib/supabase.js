import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_ANON_KEY

/** 沒設定環境變數時為 null，前端自動改用假資料 */
export const supabase = url && key ? createClient(url, key) : null
