--https://github.com/lxsmnsyc/lua6502/tree/master

local bits = bit32 or require "bit32"
local AND, OR, NOT, XOR = bits.band, bits.bor, bits.bnot, bits.bxor
local lshift, rshift = bits.blshift, bits.brshift

local function byte(a) return AND(a,0xFF) end
local function short(a) return AND(a,0xFFFF) end

local function bytesToShort(lo,hi) return lo + hi*0x100 end

local function not8(a) return byte(NOT(a)) end
local function and8(a, b) return byte(AND(a, b)) end
local function or8(a, b) return byte(OR(a, b)) end 
local function xor8(a, b) return byte(XOR(a, b)) end

local function not16(a) return short(NOT(a)) end
local function and16(a, b) return short(AND(a, b)) end
local function or16(a, b) return short(OR(a, b)) end 
local function xor16(a, b) return short(XOR(a, b)) end

local floor = math.floor

local SIGN      = 0x80
local OVERFLOW  = 0x40
local CONSTANT  = 0x20
local BREAK     = 0x10
local DECIMAL   = 0x08
local INTERRUPT = 0x04
local ZERO      = 0x02
local CARRY     = 0x01

local N_SIGN      = 0x7F
local N_OVERFLOW  = 0xBF
local N_CONSTANT  = 0xDF
local N_BREAK     = 0xEF
local N_DECIMAL   = 0xF7
local N_INTERRUPT = 0xFB
local N_ZERO      = 0xFD
local N_CARRY     = 0xFE

local STACK_OFFSET = 0x100

local read, write

local function Pointer(address)
    return {
        address = short(address),
        get = function(self) return read(self.address) end,
        set = function(self,v) write(self.address,byte(v)) end,
        getWithOffset = function(self,offset) return read(short(self.address+offset)) end
    }
end


local pc = 0
local sp = 0
local A  = 0
local X  = 0
local Y  = 0
local status = 0
local cycles = 0
local illegal = false
local addressingTable, opcodeTable

local ARef = {get = function(self) return A end, set = function(self,value) A = value end}

local irqvh = Pointer(0xFFFF)
local irqvl = Pointer(0xFFFE)
local rstvh = Pointer(0xFFFD)
local rstvl = Pointer(0xFFFC)
local nmivh = Pointer(0xFFFB)
local nmivl = Pointer(0xFFFA)

local function SET_SIGN      (x) status = x and OR(status, SIGN)       or AND(status, N_SIGN)      end
local function SET_OVERFLOW  (x) status = x and OR(status, OVERFLOW)   or AND(status, N_OVERFLOW)  end
local function SET_CONSTANT  (x) status = x and OR(status, CONSTANT)   or AND(status, N_CONSTANT)  end
local function SET_BREAK     (x) status = x and OR(status, BREAK)      or AND(status, N_BREAK)     end
local function SET_DECIMAL   (x) status = x and OR(status, DECIMAL)    or AND(status, N_DECIMAL)   end
local function SET_INTERRUPT (x) status = x and OR(status, INTERRUPT)  or AND(status, N_INTERRUPT) end
local function SET_ZERO      (x) status = x and OR(status, ZERO)       or AND(status, N_ZERO)      end
local function SET_CARRY     (x) status = x and OR(status, CARRY)      or AND(status, N_CARRY)     end

local function getflag(x, y)
    return floor(AND(x, y)/y)
end 

local function checkflag(x, y)
    return getflag(x, y) == 1
end


local function immediate()
    local tmp = pc 
    pc = short(pc + 1)
    return tmp
end

local function zeroPage(offset)
    return byte(read(immediate())+offset)
end

local function absolute(offset)
    return short(bytesToShort(read(immediate()),read(immediate()))+offset)
end

local function indirect()
    local a = absolute()
    return short(bytesToShort(read(a),read(a+1)))
end


local function acc() return ARef end

local function imp() return nil end 

local function imm() 
    return Pointer(immediate())
end

local function zer()
    return Pointer(zeroPage(0))
end

local function abs()
    return Pointer(absolute(0))
end

local function rel()
    local offset = imm():get()
    if(checkflag(offset, 0x80)) then
        offset = or16(offset, 0xff00)
    end
    return Pointer(pc + offset)
end

local function ind()
    return Pointer(indirect())
end

local function zex() return Pointer(zeroPage(X)) end
local function zey() return Pointer(zeroPage(Y)) end

local function abx() return Pointer(absolute(X)) end 
local function aby() return Pointer(absolute(Y)) end

local function idx()
    local zp = Pointer(byte(imm():get()+X))
    return Pointer(bytesToShort(zp:get(),zp:getWithOffset(1)))
end

local function idy()
    local zp = zer()
    return Pointer(bytesToShort(zp:get(),zp:getWithOffset(1))+Y)
end


local function reset()
    A = 0
    X = 0
    Y = 0
    pc = bytesToShort(rstvl:get(),rstvh:get())
    sp = 0xFD
    status = CONSTANT
    cycles  = 6
    illegal = false 
end

local function push(src)
    write(STACK_OFFSET + sp, src)
    sp = byte(sp - 1)
end

local function pop()
    sp = byte(sp + 1)
    return read(STACK_OFFSET + sp)
end

local function nmi()
    push(rshift(pc,8))
    push(byte(pc))
    push(status)

    SET_INTERRUPT(true)
    pc = bytesToShort(nmivl:get(),nmivh:get())
end

local function irq()
    if (checkflag(status, INTERRUPT)) then return end

    push(rshift(pc,8))
    push(byte(pc))
    push(status)

    SET_INTERRUPT(true)
    pc = bytesToShort(irqvl:get(),irqvh:get())
end

local function exec(addr, code)
    return code(addr())
end

local function run(n)
    local start = cycles
    local opcode

    while(start + n > cycles and not illegal) do
        opcode = read(immediate())
        --print("execing",opcode)
        if exec(addressingTable[opcode], opcodeTable[opcode]) then
            return 1
        end
        cycles = cycles + 1
    end

    if illegal then
        return 2
    end

    return 0
end

local function ILLEGAL() illegal = true end

local function setFlagsSZ(data)
    SET_SIGN(data >= 0x80)
    SET_ZERO(data == 0)
end

local function adc(src)
    local m = src:get()
    local tmp = m + A + getflag(status, CARRY)
    SET_ZERO(not(checkflag(tmp, 0xFF)))
    if(checkflag(status, DECIMAL)) then
        if(and8(A, 0xF) + and8(m, 0xF) + getflag(status, CARRY) > 9) then
            tmp = tmp + 6
        end 
        SET_SIGN(checkflag(tmp, 0x80))
        SET_OVERFLOW(not (checkflag(xor8(A, m), 0x80) and checkflag(xor8(A, tmp), 0x80)))
        if(tmp > 0x99) then
            tmp = tmp + 96
        end
    else
        SET_SIGN(checkflag(tmp, 0x80))
        SET_OVERFLOW(not (checkflag(xor8(A, m), 0x80) and checkflag(xor8(A, tmp), 0x80)))
    end
    SET_CARRY(tmp >= 0x100)
    A = tmp
end

local function ano(src)
    local res = and8(src:get(), A)
    setFlagsSZ(res)
    A = res
end

local function asl(src)
    local m = src:get()
    SET_CARRY(m >= 0x80)
    m = byte(lshift(m,1))
    setFlagsSZ(m)
    src:set(m)
end

local function bcc(src)
    pc = (getflag(status, CARRY) == 0) and src.address or pc 
end 

local function bcs(src)
    pc = (getflag(status, CARRY) == 1) and src.address or pc 
end

local function beq(src)
    pc = (getflag(status, ZERO) == 1) and src.address or pc 
end

local function bit(src)
    local m = src:get()
    status = or8(and8(status, 0x3f), and8(m, 0xc0))
    SET_ZERO(and8(A,m) == 0)
end

local function bmi(src)
    pc = (getflag(status, SIGN) == 1) and src.address or pc 
end

local function bne(src)
    pc = (getflag(status, ZERO) == 0) and src.address or pc 
end

local function bpl(src)
    pc = (getflag(status, SIGN) == 0) and src.address or pc 
end

local function brk(src)
    pc = short(pc + 1)

    push(rshift(pc,8))
    push(byte(pc))
    push(or8(status, BREAK))

    SET_INTERRUPT(true)
    pc = bytesToShort(irqvl:get(),irqvh:get())
end

local function bvc(src)
    pc = (getflag(status, OVERFLOW) == 0) and src.address or pc 
end

local function bvs(src)
    pc = (getflag(status, OVERFLOW) == 1) and src.address or pc 
end

local function clc(src) SET_CARRY(false) end
local function cld(src) SET_DECIMAL(false) end
local function cli(src) SET_INTERRUPT(false) end
local function clv(src) SET_OVERFLOW(false) end

local function compare(reg,src)
    local tmp = reg - src:get()
    SET_CARRY(tmp >= 0)
    SET_SIGN(checkflag(tmp, 0x80))
    SET_ZERO(and8(tmp, 0xff) == 0)
end

local function cmp(src)
    compare(A,src)
end

local function cpx(src)
    compare(X,src)
end

local function cpy(src)
    compare(Y,src)
end

local function dec(src)
    local m = byte(src:get()-1)
    setFlagsSZ(m)
    src:set(m)
end

local function dex(src)
    X = byte(X-1)
    setFlagsSZ(X)
end 

local function dey(src)
    Y = byte(Y-1)
    setFlagsSZ(Y)
end

local function eor(src)
    A = xor8(A, src:get())
    SET_SIGN(A > 0x80)
    SET_ZERO(A == 0) 
end

local function inc(src)
    local m = byte(src:get()+1)
    setFlagsSZ(m)
    src:set(m)
end

local function inx(src)
    X = byte(X+1)
    setFlagsSZ(X)
end

local function iny(src)
    Y = byte(Y+1)
    setFlagsSZ(Y)
end

local function jmp(src) pc = src.address end

local function jsr(src)
    pc = short(pc - 1)
    push(rshift(pc,8))
    push(byte(pc))
    pc = src.address
end

local function lda(src)
    A = src:get()
    setFlagsSZ(A)
end

local function ldx(src)
    X = src:get()
    setFlagsSZ(X)
end

local function ldy(src)
    Y = src:get()
    setFlagsSZ(Y)
end

local function lsr(src)
    local m = src:get()
    SET_CARRY((m % 2) == 1)
    m = rshift(m,1)
    setFlagsSZ(m)
    src:set(m)
end

local function nop(src) end

local function ora(src)
    A = or8(A, src:get())
    setFlagsSZ(A)
end

local function pha(src)
    push(A)
end

local function php(src)
    push(or8(status, BREAK))
end

local function pla(src)
    local m = pop()
    SET_SIGN(m > 0x80)
    SET_ZERO(m == 0)
    A = m
end

local function plp(src)
    status = byte(pop())
    SET_CONSTANT(true)
    SET_BREAK(false)
end

local function rol(src)
    m = lshift(src:get(),1)+AND(status,CARRY)
    SET_CARRY(m >= 0x100)
    m = byte(m)
    setFlagsSZ(m)
    src:set(m)
end 

local function ror(src) 
    local m = OR(src:get(), lshift(AND(status,CARRY),8))
    SET_CARRY((m % 2) == 1)
    m = rshift(m,1) 
    m = byte(m)
    setFlagsSZ(m)
    src:set(m)
end 

local function rti(src)
    status = or8(and8(pop(),N_BREAK),CONSTANT)
    pc = bytesToShort(pop(),pop())
end

local function rts(src)
    pc = short(bytesToShort(pop(),pop()) + 1)
end

local function sbc(src)
    local m = src:get()
    local tmp = A - m - XOR(getflag(status,CARRY),1)
    setFlagsSZ(tmp)
    SET_OVERFLOW(not (checkflag(xor8(A, m), 0x80) and checkflag(xor8(A, tmp), 0x80)))
    if(checkflag(status, DECIMAL)) then
        if(and8(A, 0xF) - getflag(status, CARRY) < and8(m, 0xF)) then
            tmp = tmp - 6
        end 
        if(tmp > 0x99) then
            tmp = tmp - 0x60
        end
    end
    SET_CARRY(tmp >= 0)
    A = and8(tmp, 0xff)
end

local function sec(src) SET_CARRY(true) end
local function sed(src) SET_DECIMAL(true) end
local function sei(src) SET_INTERRUPT(true) end

local function sta(src)
    src:set(A)
end
local function stx(src)
    src:set(X)
end
local function sty(src)
    src:set(Y)
end

local function tax(src)
    X = A
    setFlagsSZ(X)
end

local function tay(src)
    Y = A
    setFlagsSZ(Y)
end

local function tsx(src)
    X = sp
    SET_SIGN(X > 0x80)
    SET_ZERO(X == 0)
end

local function txa(src)
    A = X
    setFlagsSZ(A)
end

local function txs(src)
    sp = X()
end

local function tya(src)
    A = Y
    setFlagsSZ(A)
end

local function jam(src)
    ILLEGAL()
end

local function ent(src)
    return true
end

local function dump()
    return {
        pc = pc,
        sp = sp,
        a  = A,
        x  = X,
        y  = Y,
        status = status,
        illegal = illegal,
        cycles = cycles
    }
end

local function dumpString()
    return string.format("")
end

local lax, sax, dcp, isb = nop, nop, nop, nop
local slo, rla, sre, rra = nop, nop, nop, nop

addressingTable = {
    --[[        | x0  | x1  | x2  | x3  | x4  | x5  | x6  | x7  | x8  | x9  | xA  | xB  | xC  | xD  | xE  | xF  |         ]]
[0]=--[[ 0x ]]    imp,  idx,  imp,  idx,  zer,  zer,  zer,  zer,  imp,  imm,  acc,  imm,  abs,  abs,  abs,  abs,  --[[ 0x ]]
    --[[ 1x ]]    rel,  idy,  imp,  idy,  zex,  zex,  zex,  zex,  imp,  aby,  imp,  aby,  abx,  abx,  abx,  abx,  --[[ 1x ]]
    --[[ 2x ]]    abs,  idx,  imp,  idx,  zer,  zer,  zer,  zer,  imp,  imm,  acc,  imm,  abs,  abs,  abs,  abs,  --[[ 2x ]]
    --[[ 3x ]]    rel,  idy,  imp,  idy,  zex,  zex,  zex,  zex,  imp,  aby,  imp,  aby,  abx,  abx,  abx,  abx,  --[[ 3x ]]
    --[[ 4x ]]    imp,  idx,  imp,  idx,  zer,  zer,  zer,  zer,  imp,  imm,  acc,  imm,  abs,  abs,  abs,  abs,  --[[ 4x ]]
    --[[ 5x ]]    rel,  idy,  imp,  idy,  zex,  zex,  zex,  zex,  imp,  aby,  imp,  aby,  abx,  abx,  abx,  abx,  --[[ 5x ]]
    --[[ 6x ]]    imp,  idx,  imp,  idx,  zer,  zer,  zer,  zer,  imp,  imm,  acc,  imm,  ind,  abs,  abs,  abs,  --[[ 6x ]]
    --[[ 7x ]]    rel,  idy,  imp,  idy,  zex,  zex,  zex,  zex,  imp,  aby,  imp,  aby,  abx,  abx,  abx,  abx,  --[[ 7x ]]
    --[[ 8x ]]    imm,  idx,  imm,  idx,  zer,  zer,  zer,  zer,  imp,  imm,  imp,  imm,  abs,  abs,  abs,  abs,  --[[ 8x ]]
    --[[ 9x ]]    rel,  idy,  imp,  idy,  zex,  zex,  zey,  zey,  imp,  aby,  imp,  aby,  abx,  abx,  aby,  aby,  --[[ 9x ]]
    --[[ Ax ]]    imm,  idx,  imm,  idx,  zer,  zer,  zer,  zer,  imp,  imm,  imp,  imm,  abs,  abs,  abs,  abs,  --[[ Ax ]]
    --[[ Bx ]]    rel,  idy,  imp,  idy,  zex,  zex,  zey,  zey,  imp,  aby,  imp,  aby,  abx,  abx,  aby,  aby,  --[[ Bx ]]
    --[[ Cx ]]    imm,  idx,  imm,  idx,  zer,  zer,  zer,  zer,  imp,  imm,  imp,  imm,  abs,  abs,  abs,  abs,  --[[ Cx ]]
    --[[ Dx ]]    rel,  idy,  imp,  idy,  zex,  zex,  zex,  zex,  imp,  aby,  imp,  aby,  abx,  abx,  abx,  abx,  --[[ Dx ]]
    --[[ Ex ]]    imm,  idx,  imm,  idx,  zer,  zer,  zer,  zer,  imp,  imm,  imp,  imm,  abs,  abs,  abs,  abs,  --[[ Ex ]]
    --[[ Fx ]]    rel,  idy,  imp,  idy,  zex,  zex,  zex,  zex,  imp,  aby,  imp,  aby,  abx,  abx,  abx,  abx   --[[ Fx ]]
}

opcodeTable = {
    --[[        | x0  | x1  | x2  | x3  | x4  | x5  | x6  | x7  | x8  | x9  | xA  | xB  | xC  | xD  | xE  | xF  |        ]]
[0]=--[[ 0x ]]    brk,  ora,  jam,  slo,  nop,  ora,  asl,  slo,  php,  ora,  asl,  nop,  nop,  ora,  asl,  slo, --[[ 0x ]]
    --[[ 1x ]]    bpl,  ora,  jam,  slo,  nop,  ora,  asl,  slo,  clc,  ora,  nop,  slo,  nop,  ora,  asl,  slo, --[[ 1x ]]
    --[[ 2x ]]    jsr,  ano,  jam,  rla,  bit,  ano,  rol,  rla,  plp,  ano,  rol,  nop,  bit,  ano,  rol,  rla, --[[ 2x ]]
    --[[ 3x ]]    bmi,  ano,  jam,  rla,  nop,  ano,  rol,  rla,  sec,  ano,  nop,  rla,  nop,  ano,  rol,  rla, --[[ 3x ]]
    --[[ 4x ]]    rti,  eor,  jam,  sre,  nop,  eor,  lsr,  sre,  pha,  eor,  lsr,  nop,  jmp,  eor,  lsr,  sre, --[[ 4x ]]
    --[[ 5x ]]    bvc,  eor,  jam,  sre,  nop,  eor,  lsr,  sre,  cli,  eor,  nop,  sre,  nop,  eor,  lsr,  sre, --[[ 5x ]]
    --[[ 6x ]]    rts,  adc,  jam,  rra,  nop,  adc,  ror,  rra,  pla,  adc,  ror,  nop,  jmp,  adc,  ror,  rra, --[[ 6x ]]
    --[[ 7x ]]    bvs,  adc,  jam,  rra,  nop,  adc,  ror,  rra,  sei,  adc,  nop,  rra,  nop,  adc,  ror,  rra, --[[ 7x ]]
    --[[ 8x ]]    nop,  sta,  nop,  sax,  sty,  sta,  stx,  sax,  dey,  nop,  txa,  nop,  sty,  sta,  stx,  sax, --[[ 8x ]]
    --[[ 9x ]]    bcc,  sta,  jam,  nop,  sty,  sta,  stx,  sax,  tya,  sta,  txs,  nop,  nop,  sta,  nop,  nop, --[[ 9x ]]
    --[[ Ax ]]    ldy,  lda,  ldx,  lax,  ldy,  lda,  ldx,  lax,  tay,  lda,  tax,  nop,  ldy,  lda,  ldx,  lax, --[[ Ax ]]
    --[[ Bx ]]    bcs,  lda,  jam,  lax,  ldy,  lda,  ldx,  lax,  clv,  lda,  tsx,  lax,  ldy,  lda,  ldx,  lax, --[[ Bx ]]
    --[[ Cx ]]    cpy,  cmp,  nop,  dcp,  cpy,  cmp,  dec,  dcp,  iny,  cmp,  dex,  nop,  cpy,  cmp,  dec,  dcp, --[[ Cx ]]
    --[[ Dx ]]    bne,  cmp,  jam,  dcp,  nop,  cmp,  dec,  dcp,  cld,  cmp,  nop,  dcp,  nop,  cmp,  dec,  dcp, --[[ Dx ]]
    --[[ Ex ]]    cpx,  sbc,  nop,  isb,  cpx,  sbc,  inc,  isb,  inx,  sbc,  nop,  sbc,  cpx,  sbc,  inc,  isb, --[[ Ex ]]
    --[[ Fx ]]    beq,  sbc,  ent,  isb,  nop,  sbc,  inc,  isb,  sed,  sbc,  nop,  isb,  nop,  sbc,  inc,  isb  --[[ Fx ]]
}

return function (r, w)
    read = r
    write = w

    return {
        nmi = nmi, 
        irq = irq, 
        reset = reset, 
        run = run,

        dump = dump,
        dumpString = dumpString,
    }
end
