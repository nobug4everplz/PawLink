import { reactive } from 'vue'
import { supabase } from './supabase'

/** 全域登入狀態：user 為 null 代表訪客 */
export const auth = reactive({ user: null, profile: null, ready: false })

async function loadProfile(user) {
  auth.user = user
  if (!user) { auth.profile = null; return }
  const { data } = await supabase.from('profiles').select('id,display_name,role').eq('id', user.id).maybeSingle()
  auth.profile = data
}

export async function initAuth() {
  if (!supabase) { auth.ready = true; return }
  const { data } = await supabase.auth.getSession()
  await loadProfile(data.session?.user ?? null)
  supabase.auth.onAuthStateChange((_e, session) => { loadProfile(session?.user ?? null) })
  auth.ready = true
}

export const isLoggedIn = () => !!auth.user
export const isAdmin = () => auth.profile?.role === 'admin'

export async function signIn(email, password) {
  const { error } = await supabase.auth.signInWithPassword({ email, password })
  if (error) throw error
}
export async function signUp(email, password, displayName) {
  const { data, error } = await supabase.auth.signUp({ email, password, options: { data: { display_name: displayName } } })
  if (error) throw error
  return data // data.session 為 null 代表需要先收信驗證
}
export async function signOut() { await supabase.auth.signOut() }
