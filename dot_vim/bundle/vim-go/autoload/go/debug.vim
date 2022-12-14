scriptencoding utf-8

if !exists('s:state')
  let s:state = {
      \ 'rpcid': 1,
      \ 'running': 0,
      \ 'breakpoint': {},
      \ 'currentThread': {},
      \ 'localVars': {},
      \ 'functionArgs': {},
      \ 'message': [],
      \ 'is_test': 0,
      \}

  if go#util#HasDebug('debugger-state')
     call go#config#SetDebugDiag(s:state)
  endif
endif

if !exists('s:start_args')
  let s:start_args = []
endif

function! s:groutineID() abort
  return s:state['currentThread'].goroutineID
endfunction

function! s:exit(job, status) abort
  if has_key(s:state, 'job')
    call remove(s:state, 'job')
  endif
  call s:clearState()
  if a:status > 0
    call go#util#EchoError(s:state['message'])
  endif
endfunction

function! s:logger(prefix, ch, msg) abort
  let l:cur_win = bufwinnr('')
  let l:log_win = bufwinnr(bufnr('__GODEBUG_OUTPUT__'))
  if l:log_win == -1
    return
  endif
  exe l:log_win 'wincmd w'

  try
    setlocal modifiable
    if getline(1) == ''
      call setline('$', a:prefix . a:msg)
    else
      call append('$', a:prefix . a:msg)
    endif
    normal! G
    setlocal nomodifiable
  finally
    exe l:cur_win 'wincmd w'
  endtry
endfunction

function! s:call_jsonrpc(method, ...) abort
  if go#util#HasDebug('debugger-commands')
    echom 'sending to dlv ' . a:method
  endif

  if len(a:000) > 0 && type(a:000[0]) == v:t_func
     let Cb = a:000[0]
     let args = a:000[1:]
  else
     let Cb = v:none
     let args = a:000
  endif
  let s:state['rpcid'] += 1
  let req_json = json_encode({
      \  'id': s:state['rpcid'],
      \  'method': a:method,
      \  'params': args,
      \})

  try
    " Use callback
    if type(Cb) == v:t_func
      let s:ch = ch_open('127.0.0.1:8181', {'mode': 'nl', 'callback': Cb})
      call ch_sendraw(s:ch, req_json)

      if go#util#HasDebug('debugger-commands')
        let g:go_debug_commands = add(g:go_debug_commands, {
              \ 'request':  req_json,
              \ 'response': Cb,
        \ })
      endif
      return
    endif

    let ch = ch_open('127.0.0.1:8181', {'mode': 'nl', 'timeout': 20000})
    call ch_sendraw(ch, req_json)
    let resp_json = ch_readraw(ch)

    if go#util#HasDebug('debugger-commands')
      let g:go_debug_commands = add(g:go_debug_commands, {
            \ 'request':  req_json,
            \ 'response': resp_json,
      \ })
    endif

    let obj = json_decode(resp_json)
    if type(obj) == v:t_dict && has_key(obj, 'error') && !empty(obj.error)
      throw obj.error
    endif
    return obj
  catch
    throw substitute(v:exception, '^Vim', '', '')
  endtry
endfunction

" Update the location of the current breakpoint or line we're halted on based on
" response from dlv.
function! s:update_breakpoint(res) abort
  if type(a:res) ==# v:t_none
    return
  endif

  let state = a:res.result.State
  if !has_key(state, 'currentThread')
    return
  endif

  let s:state['currentThread'] = state.currentThread
  let bufs = filter(map(range(1, winnr('$')), '[v:val,bufname(winbufnr(v:val))]'), 'v:val[1]=~"\.go$"')
  if len(bufs) == 0
    return
  endif

  exe bufs[0][0] 'wincmd w'
  let filename = state.currentThread.file
  let linenr = state.currentThread.line
  let oldfile = fnamemodify(expand('%'), ':p:gs!\\!/!')
  if oldfile != filename
    silent! exe 'edit' filename
  endif
  silent! exe 'norm!' linenr.'G'
  silent! normal! zvzz
  silent! sign unplace 9999
  silent! exe 'sign place 9999 line=' . linenr . ' name=godebugcurline file=' . filename
endfunction

" Populate the stacktrace window.
function! s:show_stacktrace(res) abort
  if !has_key(a:res, 'result')
    return
  endif

  let l:stack_win = bufwinnr(bufnr('__GODEBUG_STACKTRACE__'))
  if l:stack_win == -1
    return
  endif

  let l:cur_win = bufwinnr('')
  exe l:stack_win 'wincmd w'

  try
    setlocal modifiable
    silent %delete _
    for i in range(len(a:res.result.Locations))
      let loc = a:res.result.Locations[i]
      call setline(i+1, printf('%s - %s:%d', loc.function.name, fnamemodify(loc.file, ':p'), loc.line))
    endfor
  finally
    setlocal nomodifiable
    exe l:cur_win 'wincmd w'
  endtry
endfunction

" Populate the variable window.
function! s:show_variables() abort
  let l:var_win = bufwinnr(bufnr('__GODEBUG_VARIABLES__'))
  if l:var_win == -1
    return
  endif

  let l:cur_win = bufwinnr('')
  exe l:var_win 'wincmd w'

  try
    setlocal modifiable
    silent %delete _

    let v = []
    let v += ['# Local Variables']
    if type(get(s:state, 'localVars', [])) is type([])
      for c in s:state['localVars']
        let v += split(s:eval_tree(c, 0), "\n")
      endfor
    endif

    let v += ['']
    let v += ['# Function Arguments']
    if type(get(s:state, 'functionArgs', [])) is type([])
      for c in s:state['functionArgs']
        let v += split(s:eval_tree(c, 0), "\n")
      endfor
    endif

    call setline(1, v)
  finally
    setlocal nomodifiable
    exe l:cur_win 'wincmd w'
  endtry
endfunction

function! s:clearState() abort
  let s:state['currentThread'] = {}
  let s:state['localVars'] = {}
  let s:state['functionArgs'] = {}
  let s:state['message'] = []
  silent! sign unplace 9999
endfunction

function! s:stop() abort
  call s:clearState()
  if has_key(s:state, 'job')
    call job_stop(s:state['job'])
    call remove(s:state, 'job')
  endif
endfunction

function! go#debug#Stop() abort
  " Remove signs.
  for k in keys(s:state['breakpoint'])
    let bt = s:state['breakpoint'][k]
    if bt.id >= 0
      silent exe 'sign unplace ' . bt.id
    endif
  endfor

  " Remove all commands and add back the default commands.
  for k in map(split(execute('command GoDebug'), "\n")[1:], 'matchstr(v:val, "^\\s*\\zs\\S\\+")')
    exe 'delcommand' k
  endfor
  command! -nargs=* -complete=customlist,go#package#Complete GoDebugStart call go#debug#Start(0, <f-args>)
  command! -nargs=* -complete=customlist,go#package#Complete GoDebugTest  call go#debug#Start(1, <f-args>)
  command! -nargs=? GoDebugBreakpoint call go#debug#Breakpoint(<f-args>)

  " Remove all mappings.
  for k in map(split(execute('map <Plug>(go-debug-'), "\n")[1:], 'matchstr(v:val, "^n\\s\\+\\zs\\S\\+")')
    exe 'unmap' k
  endfor

  call s:stop()

  let bufs = filter(map(range(1, winnr('$')), '[v:val,bufname(winbufnr(v:val))]'), 'v:val[1]=~"\.go$"')
  if len(bufs) > 0
    exe bufs[0][0] 'wincmd w'
  else
    wincmd p
  endif
  silent! exe bufwinnr(bufnr('__GODEBUG_STACKTRACE__')) 'wincmd c'
  silent! exe bufwinnr(bufnr('__GODEBUG_VARIABLES__')) 'wincmd c'
  silent! exe bufwinnr(bufnr('__GODEBUG_OUTPUT__')) 'wincmd c'

  set noballooneval
  set balloonexpr=

  augroup vim-go-debug
    autocmd!
  augroup END
  augroup! vim-go-debug
endfunction

function! s:goto_file() abort
  let m = matchlist(getline('.'), ' - \(.*\):\([0-9]\+\)$')
  if m[1] == ''
    return
  endif
  let bufs = filter(map(range(1, winnr('$')), '[v:val,bufname(winbufnr(v:val))]'), 'v:val[1]=~"\.go$"')
  if len(bufs) == 0
    return
  endif
  exe bufs[0][0] 'wincmd w'
  let filename = m[1]
  let linenr = m[2]
  let oldfile = fnamemodify(expand('%'), ':p:gs!\\!/!')
  if oldfile != filename
    silent! exe 'edit' filename
  endif
  silent! exe 'norm!' linenr.'G'
  silent! normal! zvzz
endfunction

function! s:delete_expands()
  let nr = line('.')
  while 1
    let l = getline(nr+1)
    if empty(l) || l =~ '^\S'
      return
    endif
    silent! exe (nr+1) . 'd _'
  endwhile
  silent! exe 'norm!' nr.'G'
endfunction

function! s:expand_var() abort
  " Get name from struct line.
  let name = matchstr(getline('.'), '^[^:]\+\ze: [a-zA-Z0-9\.??]\+{\.\.\.}$')
  " Anonymous struct
  if name == ''
    let name = matchstr(getline('.'), '^[^:]\+\ze: struct {.\{-}}$')
  endif

  if name != ''
    setlocal modifiable
    let not_open = getline(line('.')+1) !~ '^ '
    let l = line('.')
    call s:delete_expands()

    if not_open
      call append(l, split(s:eval(name), "\n")[1:])
    endif
    silent! exe 'norm!' l.'G'
    setlocal nomodifiable
    return
  endif

  " Expand maps
  let m = matchlist(getline('.'), '^[^:]\+\ze: map.\{-}\[\(\d\+\)\]$')
  if len(m) > 0 && m[1] != ''
    setlocal modifiable
    let not_open = getline(line('.')+1) !~ '^ '
    let l = line('.')
    call s:delete_expands()
    if not_open
      " TODO: Not sure how to do this yet... Need to get keys of the map.
      " let vs = ''
      " for i in range(0, min([10, m[1]-1]))
      "   let vs .= ' ' . s:eval(printf("%s[%s]", m[0], ))
      " endfor
      " call append(l, split(vs, "\n"))
    endif

    silent! exe 'norm!' l.'G'
    setlocal nomodifiable
    return
  endif

  " Expand string.
  let m = matchlist(getline('.'), '^\([^:]\+\)\ze: \(string\)\[\([0-9]\+\)\]\(: .\{-}\)\?$')
  if len(m) > 0 && m[1] != ''
    setlocal modifiable
    let not_open = getline(line('.')+1) !~ '^ '
    let l = line('.')
    call s:delete_expands()

    if not_open
      let vs = ''
      for i in range(0, min([10, m[3]-1]))
        let vs .= ' ' . s:eval(m[1] . '[' . i . ']')
      endfor
      call append(l, split(vs, "\n"))
    endif

    silent! exe 'norm!' l.'G'
    setlocal nomodifiable
    return
  endif

  " Expand slice.
  let m = matchlist(getline('.'), '^\([^:]\+\)\ze: \(\[\]\w\{-}\)\[\([0-9]\+\)\]$')
  if len(m) > 0 && m[1] != ''
    setlocal modifiable
    let not_open = getline(line('.')+1) !~ '^ '
    let l = line('.')
    call s:delete_expands()

    if not_open
      let vs = ''
      for i in range(0, min([10, m[3]-1]))
        let vs .= ' ' . s:eval(m[1] . '[' . i . ']')
      endfor
      call append(l, split(vs, "\n"))
    endif
    silent! exe 'norm!' l.'G'
    setlocal nomodifiable
    return
  endif
endfunction

function! s:start_cb(ch, json) abort
  let res = json_decode(a:json)
  if type(res) == v:t_dict && has_key(res, 'error') && !empty(res.error)
    throw res.error
  endif
  if empty(res) || !has_key(res, 'result')
    return
  endif
  for bt in res.result.Breakpoints
    if bt.id >= 0
      let s:state['breakpoint'][bt.id] = bt
      exe 'sign place '. bt.id .' line=' . bt.line . ' name=godebugbreakpoint file=' . bt.file
    endif
  endfor

  let oldbuf = bufnr('%')
  silent! only!

  let winnum = bufwinnr(bufnr('__GODEBUG_STACKTRACE__'))
  if winnum != -1
    return
  endif

  let debugwindows = go#config#DebugWindows()
  if has_key(debugwindows, "stack") && debugwindows['stack'] != ''
    exe 'silent ' . debugwindows['stack']
    silent file `='__GODEBUG_STACKTRACE__'`
    setlocal buftype=nofile bufhidden=wipe nomodified nobuflisted noswapfile nowrap nonumber nocursorline
    setlocal filetype=godebugstacktrace
    nmap <buffer> <cr> :<c-u>call <SID>goto_file()<cr>
    nmap <buffer> q <Plug>(go-debug-stop)
  endif

  if has_key(debugwindows, "out") && debugwindows['out'] != ''
    exe 'silent ' . debugwindows['out']
    silent file `='__GODEBUG_OUTPUT__'`
    setlocal buftype=nofile bufhidden=wipe nomodified nobuflisted noswapfile nowrap nonumber nocursorline
    setlocal filetype=godebugoutput
    nmap <buffer> q <Plug>(go-debug-stop)
  endif

  if has_key(debugwindows, "vars") && debugwindows['vars'] != ''
    exe 'silent ' . debugwindows['vars']
    silent file `='__GODEBUG_VARIABLES__'`
    setlocal buftype=nofile bufhidden=wipe nomodified nobuflisted noswapfile nowrap nonumber nocursorline
    setlocal filetype=godebugvariables
    call append(0, ["# Local Variables", "", "# Function Arguments"])
    nmap <buffer> <silent> <cr> :<c-u>call <SID>expand_var()<cr>
    nmap <buffer> q <Plug>(go-debug-stop)
  endif

  silent! delcommand GoDebugStart
  silent! delcommand GoDebugTest
  command! -nargs=0 GoDebugContinue   call go#debug#Stack('continue')
  command! -nargs=0 GoDebugNext       call go#debug#Stack('next')
  command! -nargs=0 GoDebugStep       call go#debug#Stack('step')
  command! -nargs=0 GoDebugStepOut    call go#debug#Stack('stepOut')
  command! -nargs=0 GoDebugRestart    call go#debug#Restart()
  command! -nargs=0 GoDebugStop       call go#debug#Stop()
  command! -nargs=* GoDebugSet        call go#debug#Set(<f-args>)
  command! -nargs=1 GoDebugPrint      call go#debug#Print(<q-args>)

  nnoremap <silent> <Plug>(go-debug-breakpoint) :<C-u>call go#debug#Breakpoint()<CR>
  nnoremap <silent> <Plug>(go-debug-next)       :<C-u>call go#debug#Stack('next')<CR>
  nnoremap <silent> <Plug>(go-debug-step)       :<C-u>call go#debug#Stack('step')<CR>
  nnoremap <silent> <Plug>(go-debug-stepout)    :<C-u>call go#debug#Stack('stepout')<CR>
  nnoremap <silent> <Plug>(go-debug-continue)   :<C-u>call go#debug#Stack('continue')<CR>
  nnoremap <silent> <Plug>(go-debug-stop)       :<C-u>call go#debug#Stop()<CR>
  nnoremap <silent> <Plug>(go-debug-print)      :<C-u>call go#debug#Print(expand('<cword>'))<CR>

  set balloonexpr=go#debug#BalloonExpr()
  set ballooneval

  exe bufwinnr(oldbuf) 'wincmd w'

  augroup vim-go-debug
    autocmd!
    autocmd FileType go nmap <buffer> <F5>   <Plug>(go-debug-continue)
    autocmd FileType go nmap <buffer> <F6>   <Plug>(go-debug-print)
    autocmd FileType go nmap <buffer> <F9>   <Plug>(go-debug-breakpoint)
    autocmd FileType go nmap <buffer> <F10>  <Plug>(go-debug-next)
    autocmd FileType go nmap <buffer> <F11>  <Plug>(go-debug-step)
  augroup END
  doautocmd vim-go-debug FileType go
endfunction

function! s:err_cb(ch, msg) abort
  call go#util#EchoError(a:msg)
  let s:state['message'] += [a:msg]
endfunction

function! s:out_cb(ch, msg) abort
  call go#util#EchoProgress(a:msg)
  let s:state['message'] += [a:msg]

  " TODO: why do this in this callback?
  if stridx(a:msg, go#config#DebugAddress()) != -1
    call ch_setoptions(a:ch, {
      \ 'out_cb': function('s:logger', ['OUT: ']),
      \ 'err_cb': function('s:logger', ['ERR: ']),
      \})

    " Tell dlv about the breakpoints that the user added before delve started.
    let l:breaks = copy(s:state.breakpoint)
    let s:state['breakpoint'] = {}
    for l:bt in values(l:breaks)
      call go#debug#Breakpoint(bt.line)
    endfor

    call s:call_jsonrpc('RPCServer.ListBreakpoints', function('s:start_cb'))
  endif
endfunction

" Start the debug mode. The first argument is the package name to compile and
" debug, anything else will be passed to the running program.
function! go#debug#Start(is_test, ...) abort
  call go#cmd#autowrite()

  if has('nvim')
    call go#util#EchoError('This feature only works in Vim for now; Neovim is not (yet) supported. Sorry :-(')
    return
  endif
  if !go#util#has_job()
    call go#util#EchoError('This feature requires Vim 8.0.0087 or newer with +job.')
    return
  endif

  " It's already running.
  if has_key(s:state, 'job') && job_status(s:state['job']) == 'run'
    return
  endif

  let s:start_args = a:000

  if go#util#HasDebug('debugger-state')
    call go#config#SetDebugDiag(s:state)
  endif

  " cd in to test directory; this is also what running "go test" does.
  if a:is_test
    lcd %:p:h
  endif

  let s:state.is_test = a:is_test

  let dlv = go#path#CheckBinPath("dlv")
  if empty(dlv)
    return
  endif

  try
    if len(a:000) > 0
      let l:pkgname = a:1
      " Expand .; otherwise this won't work from a tmp dir.
      if l:pkgname[0] == '.'
        let l:pkgname = go#package#FromPath(getcwd()) . l:pkgname[1:]
      endif
    else
      let l:pkgname = go#package#FromPath(getcwd())
    endif

    let l:args = []
    if len(a:000) > 1
      let l:args = ['--'] + a:000[1:]
    endif

    let l:cmd = [
          \ dlv,
          \ (a:is_test ? 'test' : 'debug'),
          \ l:pkgname,
          \ '--output', tempname(),
          \ '--headless',
          \ '--api-version', '2',
          \ '--log', 'debugger',
          \ '--listen', go#config#DebugAddress(),
          \ '--accept-multiclient',
    \]

    let buildtags = go#config#BuildTags()
    if buildtags isnot ''
      let l:cmd += ['--build-flags', '--tags=' . buildtags]
    endif
    let l:cmd += l:args

    call go#util#EchoProgress('Starting GoDebug...')
    let s:state['message'] = []
    let s:state['job'] = job_start(l:cmd, {
      \ 'out_cb': function('s:out_cb'),
      \ 'err_cb': function('s:err_cb'),
      \ 'exit_cb': function('s:exit'),
      \ 'stoponexit': 'kill',
    \})
  catch
    call go#util#EchoError(v:exception)
  endtry
endfunction

" Translate a reflect kind constant to a human string.
function! s:reflect_kind(k)
  " Kind constants from Go's reflect package.
  return [
        \ 'Invalid Kind',
        \ 'Bool',
        \ 'Int',
        \ 'Int8',
        \ 'Int16',
        \ 'Int32',
        \ 'Int64',
        \ 'Uint',
        \ 'Uint8',
        \ 'Uint16',
        \ 'Uint32',
        \ 'Uint64',
        \ 'Uintptr',
        \ 'Float32',
        \ 'Float64',
        \ 'Complex64',
        \ 'Complex128',
        \ 'Array',
        \ 'Chan',
        \ 'Func',
        \ 'Interface',
        \ 'Map',
        \ 'Ptr',
        \ 'Slice',
        \ 'String',
        \ 'Struct',
        \ 'UnsafePointer',
  \ ][a:k]
endfunction

function! s:eval_tree(var, nest) abort
  if a:var.name =~ '^\~'
    return ''
  endif
  let nest = a:nest
  let v = ''
  let kind = s:reflect_kind(a:var.kind)
  if !empty(a:var.name)
    let v .= repeat(' ', nest) . a:var.name . ': '

    if kind == 'Bool'
      let v .= printf("%s\n", a:var.value)

    elseif kind == 'Struct'
      " Anonymous struct
      if a:var.type[:8] == 'struct { '
        let v .= printf("%s\n", a:var.type)
      else
        let v .= printf("%s{...}\n", a:var.type)
      endif

    elseif kind == 'String'
      let v .= printf("%s[%d]%s\n", a:var.type, a:var.len,
            \ len(a:var.value) > 0 ? ': ' . a:var.value : '')

    elseif kind == 'Slice' || kind == 'String' || kind == 'Map' || kind == 'Array'
      let v .= printf("%s[%d]\n", a:var.type, a:var.len)

    elseif kind == 'Chan' || kind == 'Func' || kind == 'Interface'
      let v .= printf("%s\n", a:var.type)

    elseif kind == 'Ptr'
      " TODO: We can do something more useful here.
      let v .= printf("%s\n", a:var.type)

    elseif kind == 'Complex64' || kind == 'Complex128'
      let v .= printf("%s%s\n", a:var.type, a:var.value)

    " Int, Float
    else
      let v .= printf("%s(%s)\n", a:var.type, a:var.value)
    endif
  else
    let nest -= 1
  endif

  if index(['Chan', 'Complex64', 'Complex128'], kind) == -1 && a:var.type != 'error'
    for c in a:var.children
      let v .= s:eval_tree(c, nest+1)
    endfor
  endif
  return v
endfunction

function! s:eval(arg) abort
  try
    let res = s:call_jsonrpc('RPCServer.State')
    let goroutineID = res.result.State.currentThread.goroutineID
    let res = s:call_jsonrpc('RPCServer.Eval', {
          \ 'expr':  a:arg,
          \ 'scope': {'GoroutineID': goroutineID}
      \ })
    return s:eval_tree(res.result.Variable, 0)
  catch
    call go#util#EchoError(v:exception)
    return ''
  endtry
endfunction

function! go#debug#BalloonExpr() abort
  silent! let l:v = s:eval(v:beval_text)
  return l:v
endfunction

function! go#debug#Print(arg) abort
  try
    echo substitute(s:eval(a:arg), "\n$", "", 0)
  catch
    call go#util#EchoError(v:exception)
  endtry
endfunction

function! s:update_variables() abort
  " FollowPointers requests pointers to be automatically dereferenced.
  " MaxVariableRecurse is how far to recurse when evaluating nested types.
  " MaxStringLen is the maximum number of bytes read from a string
  " MaxArrayValues is the maximum number of elements read from an array, a slice or a map.
  " MaxStructFields is the maximum number of fields read from a struct, -1 will read all fields.
  let l:cfg = {
        \ 'scope': {'GoroutineID': s:groutineID()},
        \ 'cfg':   {'MaxStringLen': 20, 'MaxArrayValues': 20}
        \ }

  try
    let res = s:call_jsonrpc('RPCServer.ListLocalVars', l:cfg)
    let s:state['localVars'] = res.result['Variables']
  catch
    call go#util#EchoError(v:exception)
  endtry

  try
    let res = s:call_jsonrpc('RPCServer.ListFunctionArgs', l:cfg)
    let s:state['functionArgs'] = res.result['Args']
  catch
    call go#util#EchoError(v:exception)
  endtry

  call s:show_variables()
endfunction

function! go#debug#Set(symbol, value) abort
  try
    let res = s:call_jsonrpc('RPCServer.State')
    let goroutineID = res.result.State.currentThread.goroutineID
    call s:call_jsonrpc('RPCServer.Set', {
          \ 'symbol': a:symbol,
          \ 'value':  a:value,
          \ 'scope':  {'GoroutineID': goroutineID}
    \ })
  catch
    call go#util#EchoError(v:exception)
  endtry

  call s:update_variables()
endfunction

function! s:update_stacktrace() abort
  try
    let res = s:call_jsonrpc('RPCServer.Stacktrace', {'id': s:groutineID(), 'depth': 5})
    call s:show_stacktrace(res)
  catch
    call go#util#EchoError(v:exception)
  endtry
endfunction

function! s:stack_cb(ch, json) abort
  let s:stack_name = ''
  let res = json_decode(a:json)
  if type(res) == v:t_dict && has_key(res, 'error') && !empty(res.error)
    call go#util#EchoError(res.error)
    call s:clearState()
    call go#debug#Restart()
    return
  endif

  if empty(res) || !has_key(res, 'result')
    return
  endif
  call s:update_breakpoint(res)
  call s:update_stacktrace()
  call s:update_variables()
endfunction

" Send a command to change the cursor location to Delve.
"
" a:name must be one of continue, next, step, or stepOut.
function! go#debug#Stack(name) abort
  let l:name = a:name

  " Run continue if the program hasn't started yet.
  if s:state.running is 0
    let s:state.running = 1
    let l:name = 'continue'
  endif

  " Add a breakpoint to the main.Main if the user didn't define any.
  if len(s:state['breakpoint']) is 0
    if go#debug#Breakpoint() isnot 0
      let s:state.running = 0
      return
    endif
  endif

  try
    " TODO: document why this is needed.
    if l:name is# 'next' && get(s:, 'stack_name', '') is# 'next'
      call s:call_jsonrpc('RPCServer.CancelNext')
    endif
    let s:stack_name = l:name
    call s:call_jsonrpc('RPCServer.Command', function('s:stack_cb'), {'name': l:name})
  catch
    call go#util#EchoError(v:exception)
  endtry
endfunction

function! go#debug#Restart() abort
  call go#cmd#autowrite()

  try
    call job_stop(s:state['job'])
    while has_key(s:state, 'job') && job_status(s:state['job']) is# 'run'
      sleep 50m
    endwhile

    let l:breaks = s:state['breakpoint']
    let s:state = {
        \ 'rpcid': 1,
        \ 'running': 0,
        \ 'breakpoint': {},
        \ 'currentThread': {},
        \ 'localVars': {},
        \ 'functionArgs': {},
        \ 'message': [],
        \}

    " Preserve breakpoints.
    for bt in values(l:breaks)
      " TODO: should use correct filename
      exe 'sign unplace '. bt.id .' file=' . bt.file
      call go#debug#Breakpoint(bt.line)
    endfor
    call call('go#debug#Start', s:start_args)
  catch
    call go#util#EchoError(v:exception)
  endtry
endfunction

" Report if debugger mode is active.
function! s:isActive()
  return len(s:state['message']) > 0
endfunction

" Toggle breakpoint. Returns 0 on success and 1 on failure.
function! go#debug#Breakpoint(...) abort
  let l:filename = fnamemodify(expand('%'), ':p:gs!\\!/!')

  " Get line number from argument.
  if len(a:000) > 0
    let linenr = str2nr(a:1)
    if linenr is 0
      call go#util#EchoError('not a number: ' . a:1)
      return 0
    endif
  else
    let linenr = line('.')
  endif

  try
    " Check if we already have a breakpoint for this line.
    let found = v:none
    for k in keys(s:state.breakpoint)
      let bt = s:state.breakpoint[k]
      if bt.file == l:filename && bt.line == linenr
        let found = bt
        break
      endif
    endfor

    " Remove breakpoint.
    if type(found) == v:t_dict
      call remove(s:state['breakpoint'], bt.id)
      exe 'sign unplace '. found.id .' file=' . found.file
      if s:isActive()
        let res = s:call_jsonrpc('RPCServer.ClearBreakpoint', {'id': found.id})
      endif
    " Add breakpoint.
    else
      if s:isActive()
        let res = s:call_jsonrpc('RPCServer.CreateBreakpoint', {'Breakpoint': {'file': l:filename, 'line': linenr}})
        let bt = res.result.Breakpoint
        exe 'sign place '. bt.id .' line=' . bt.line . ' name=godebugbreakpoint file=' . bt.file
        let s:state['breakpoint'][bt.id] = bt
      else
        let id = len(s:state['breakpoint']) + 1
        let s:state['breakpoint'][id] = {'id': id, 'file': l:filename, 'line': linenr}
        exe 'sign place '. id .' line=' . linenr . ' name=godebugbreakpoint file=' . l:filename
      endif
    endif
  catch
    call go#util#EchoError(v:exception)
    return 1
  endtry

  return 0
endfunction

sign define godebugbreakpoint text=> texthl=GoDebugBreakpoint
sign define godebugcurline text== linehl=GoDebugCurrent texthl=GoDebugCurrent

fun! s:hi()
  hi GoDebugBreakpoint term=standout ctermbg=117 ctermfg=0 guibg=#BAD4F5  guifg=Black
  hi GoDebugCurrent    term=reverse  ctermbg=12  ctermfg=7 guibg=DarkBlue guifg=White
endfun
augroup vim-go-breakpoint
  autocmd!
  autocmd ColorScheme * call s:hi()
augroup end
call s:hi()

" vim: sw=2 ts=2 et
