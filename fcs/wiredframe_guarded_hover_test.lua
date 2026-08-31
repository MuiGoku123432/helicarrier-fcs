-- Guarded zero-tilt hover proof for the direct wired frame.
-- FCS-DEV only; stop normal FCS and clear the flight area first.
local args={...}
local CONTROL,STATUS=42042,42043
local PROTOCOL,MODE="helicarrier.control-frame.v1","response_map_test"
local CORNERS={"FL","FR","RL","RR"}; local CORNER_SET={FL=true,FR=true,RL=true,RR=true}
local RESULT="/fcs/wiredframe_guarded_hover_result.txt"
local RATE,VALID,SHUTDOWN_VALID=10,750,5000
local PRECHECK,LIFT_LIMIT,BRAKE_LIMIT,BRAKE_MIN,HOVER,SHUTDOWN=5,2,2.25,1,6,3
local SLOT_MS,RPM=250,64
local HIGH,LOW,FALLBACK=0.200,0.14,0.07
local FALLBACK_STOP=5000
local TRIGGER_RISE,TRIGGER_VY,BRAKE_VY=0.15,0.35,0.12
local FEEDBACK_VY,FEEDBACK_ALT=0.20,0.20
local HIGH_INHIBIT_RISE=8.0
local STABLE_VY,STABLE_ALT,STABLE_HSPEED,STABLE_TILT,STABLE_MS=0.35,0.30,0.25,1.0,2000
local MAX_SAMPLE,POD_AGE=1000,1500
local MAX_RISE,MAX_FALL,MAX_HDISP=10.0,1.0,1.0
local MAX_VSPEED,MAX_HSPEED,MAX_SPEED,MAX_TILT,MAX_ANGULAR=1.5,1.0,1.75,2.0,0.35
local function finite(v)return type(v)=="number" and v==v and v>-math.huge and v<math.huge end
local function nearly(a,b)return finite(a) and finite(b) and math.abs(a-b)<=1e-9 end
local function comp(v,i,k)if type(v)~="table" then return end local n=v[i];if n==nil then n=v[k]end;return finite(n)and n or nil end
local function vec(v)local x,y,z=comp(v,1,"x"),comp(v,2,"y"),comp(v,3,"z");if x==nil or y==nil or z==nil then return end;return{x=x,y=y,z=z}end
local function mag(v)return math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)end
local function quat(p)
 if type(p)~="table" then return end;local q=p.orientation or p.rotation or p.quaternion or p;if type(q)~="table" then return end
 local v=q.v or q.vector or q;local x,y,z=comp(v,1,"x"),comp(v,2,"y"),comp(v,3,"z");local w=q.a;if not finite(w)then w=q.w end;if not finite(w)then w=q[4]end
 if x==nil or y==nil or z==nil or not finite(w)then return end;local n=math.sqrt(x*x+y*y+z*z+w*w);if n<=1e-12 then return end;return{x=x/n,y=y/n,z=z/n,w=w/n}
end
local function up(q)return{x=2*(q.x*q.y-q.w*q.z),y=1-2*(q.x*q.x+q.z*q.z),z=2*(q.y*q.z+q.w*q.x)}end
local function tilt(a,b)local u,v=up(a),up(b);return math.deg(math.acos(math.max(-1,math.min(1,u.x*v.x+u.y*v.y+u.z*v.z))))end
local function position(p)if type(p)~="table" then return end;for _,k in ipairs({"position","pos","translation","location"})do local v=vec(p[k]);if v then return v,"logical_pose."..k end end end
local function call(api,name)local f=api and api[name];if type(f)~="function" then return nil,"missing "..name end;local ok,v=pcall(f);if not ok then return nil,tostring(v)end;return v end
local function loadSublevel()if type(_G.sublevel)=="table" then return _G.sublevel,"global" end;if type(require)=="function" then local ok,v=pcall(require,"sublevel");if ok and type(v)=="table" then return v,"require" end end end
local POSITION_METHODS={"getPosition","getLogicalPosition","getContraptionPosition","getWorldPosition"}
local function sample(api)
 local a=os.epoch("utc");local pose=call(api,"getLogicalPose");local linear=call(api,"getLinearVelocity");local angular=call(api,"getAngularVelocity");local pos,source=position(pose)
 if not pos then for _,name in ipairs(POSITION_METHODS)do if type(api[name])=="function" then pos=vec(call(api,name));if pos then source=name break end end end end
 local b=os.epoch("utc");return{finishedAt=b,elapsedMs=b-a,quaternion=quat(pose),position=pos,positionSource=source,linearVelocity=vec(linear),angularVelocity=vec(angular)}
end
local function sampleValid(s)return s and s.quaternion and s.linearVelocity and s.angularVelocity and finite(s.elapsedMs)and s.elapsedMs>=0 and s.elapsedMs<=MAX_SAMPLE end
local function command(kind)
 if kind=="shutdown" then return{ionPower=0,fallbackIonPower=0,propRpm=0,tiltDegrees=0,azimuthDegrees=0,shutdown=true}end
 local power=kind=="high" and HIGH or(kind=="low" and LOW or 0)
 return{ionPower=power,fallbackIonPower=power>0 and FALLBACK or 0,fallbackStopAfterMs=FALLBACK_STOP,propRpm=RPM,tiltDegrees=0,azimuthDegrees=0,shutdown=false}
end
local function frame(session,sequence,sentAt,kind)local c={};for _,corner in ipairs(CORNERS)do c[corner]=command(kind)end;return{protocol=PROTOCOL,kind="control_frame",mode=MODE,armed=true,session=session,sequence=sequence,sentAt=sentAt,validForMs=kind=="shutdown" and SHUTDOWN_VALID or VALID,corners=c}end
local function clean(s)return type(s)=="table" and(tonumber(s.missing)or 0)==0 and(tonumber(s.duplicates)or 0)==0 and(tonumber(s.outOfOrder)or 0)==0 and(tonumber(s.invalid)or 0)==0 and(tonumber(s.expiredBeforeApply)or 0)==0 and(tonumber(s.applyErrors)or 0)==0 and(tonumber(s.fallbackCount)or 0)==0 and(tonumber(s.fallbackStops)or 0)==0 end
local function applied(s,power,rpm)return type(s)=="table" and s.appliedMode==MODE and nearly(s.appliedIonPower,power)and s.appliedPropRpm==rpm and s.appliedTiltDegrees==0 and s.appliedAzimuthDegrees==0 end
local function choose(m,target,slot)
 local e=m.rise-target;if m.rise>=HIGH_INHIBIT_RISE then return"low","absolute_high_inhibit"end;if m.verticalVelocity>=FEEDBACK_VY then return"low","upward_speed"end;if m.verticalVelocity<=-FEEDBACK_VY then return"high","downward_speed"end
 if e>=FEEDBACK_ALT then return"low","above_target"end;if e<=-FEEDBACK_ALT then return"high","below_target"end;if(slot-1)%4==0 then return"high","nominal_1_of_4"end;return"low","nominal_3_of_4"
end
local function evaluate(s,q0,r)
 local l,a=s.linearVelocity,s.angularVelocity;local m={rise=r.y,verticalVelocity=l.y,verticalSpeed=math.abs(l.y),horizontalDisplacement=math.sqrt(r.x*r.x+r.z*r.z),horizontalSpeed=math.sqrt(l.x*l.x+l.z*l.z),totalSpeed=mag(l),angularSpeed=mag(a),tiltDegrees=tilt(q0,s.quaternion)}
 if m.rise>MAX_RISE then return m,"rise limit exceeded"end;if m.rise<-MAX_FALL then return m,"fall limit exceeded"end;if m.horizontalDisplacement>MAX_HDISP then return m,"horizontal displacement limit exceeded"end
 if m.verticalSpeed>MAX_VSPEED then return m,"vertical speed limit exceeded"end;if m.horizontalSpeed>MAX_HSPEED then return m,"horizontal speed limit exceeded"end;if m.totalSpeed>MAX_SPEED then return m,"total speed limit exceeded"end
 if m.tiltDegrees>MAX_TILT then return m,"attitude limit exceeded"end;if m.angularSpeed>MAX_ANGULAR then return m,"angular-rate limit exceeded"end;return m
end
local function trigger(m)if m.rise>=TRIGGER_RISE then return"rise"end;if m.verticalVelocity>=TRIGGER_VY then return"upward_velocity"end end
local function stable(m,target)return math.abs(m.verticalVelocity)<=STABLE_VY and math.abs(m.rise-target)<=STABLE_ALT and m.horizontalSpeed<=STABLE_HSPEED and m.tiltDegrees<=STABLE_TILT end
local function selfTest()
 assert(math.floor(HIGH*15)==3 and math.floor(LOW*15)==2 and math.floor(FALLBACK*15)==1);assert(HOVER*1000%SLOT_MS==0);assert(MAX_RISE==10.0 and HIGH_INHIBIT_RISE==8.0 and HIGH_INHIBIT_RISE<MAX_RISE)
 local n={rise=1,verticalVelocity=0};assert(choose(n,1,1)=="high");assert(choose(n,1,2)=="low");assert(choose({rise=1,verticalVelocity=.21},1,1)=="low");assert(choose({rise=1,verticalVelocity=-.21},1,2)=="high");assert(choose({rise=1.21,verticalVelocity=0},1,1)=="low");assert(choose({rise=.79,verticalVelocity=0},1,2)=="high");assert(choose({rise=HIGH_INHIBIT_RISE,verticalVelocity=-1},HIGH_INHIBIT_RISE,1)=="low")
 local h,l,z=frame("s",1,1,"high"),frame("s",2,2,"low"),frame("s",3,3,"shutdown");for _,c in ipairs(CORNERS)do assert(h.corners[c].ionPower==HIGH and l.corners[c].ionPower==LOW and h.corners[c].fallbackIonPower==FALLBACK);assert(z.corners[c].ionPower==0 and z.corners[c].propRpm==0 and z.corners[c].shutdown)end
 assert(clean({})and not clean({missing=1}));print("wired guarded-hover sender self-test: PASS")
end
if args[1]=="--self-test"then selfTest()return end
if args[1]~="--guarded-hover-check"then error("use --guarded-hover-check; this is a bounded live flight test",0)end
print("ZERO-TILT GUARDED HOVER PROOF");print("Required: FCS-DEV only, normal FCS stopped, flight area clear.");print("Nominal: one 3/15 slot then three 2/15 slots; feedback overrides.")
print(string.format("Hard abort: rise %.1f, vertical speed %.1f, tilt %.1f degrees.",MAX_RISE,MAX_VSPEED,MAX_TILT));write("Type GUARDED-HOVER to continue: ");if read()~="GUARDED-HOVER"then error("operator confirmation not received",0)end
local sublevel,sublevelSource=loadSublevel();if not sublevel then error("CC:Sable sublevel API unavailable; no commands sent",0)end;local inGrid,gridError=call(sublevel,"isInPlotGrid");if gridError or inGrid~=true then error("FCS-DEV is not attached to a Sable Sub-Level; no commands sent",0)end
local baseline=sample(sublevel);if not sampleValid(baseline)then error("CC:Sable telemetry preflight failed; no commands sent",0)end;local q0,p0=baseline.quaternion,baseline.position;local started=baseline.finishedAt
local function modems()local r={};for _,name in ipairs(peripheral.getNames())do if peripheral.getType(name)=="modem"then r[#r+1]={name=name,modem=peripheral.wrap(name)}end end;return r end
local function wired()for _,e in ipairs(modems())do local ok,w=pcall(e.modem.isWireless);if ok and w==false then return e.name,e.modem end end end
local modemName,modem=wired();if not modem then error("no wired modem attached; no commands sent",0)end;for _,e in ipairs(modems())do pcall(e.modem.closeAll)end;modem.open(STATUS)
local session=string.format("%d-response-guarded-hover-%d",os.getComputerID(),os.epoch("utc"))
local latest,lastAt,lastSeq={},{},{};local preSeen,highSeen,lowSeen,hoverHigh,hoverLow,zeroSeen={},{},{},{},{},{}
local sequence,frames,active=0,0,true;local phase,inHover="idle",false;local runError,abortReason,shutdownError
local latestMetrics,latestTelemetryAt,targetRise,stableSince
local data={count=0,maxSampleMs=baseline.elapsedMs,minRise=0,maxRise=0,maxVerticalSpeed=0,maxHorizontalDisplacement=0,maxHorizontalSpeed=0,maxTotalSpeed=0,maxAngularSpeed=0,maxTiltDegrees=0,positionSource=p0 and(baseline.positionSource or"absolute_position")or"integrated_linear_velocity",triggerReason=nil,brakeSamples=0,brakeFinalVelocity=nil,hoverSamples=0,stableWindowSeen=false,highSlots=0,lowSlots=0,feedbackHigh=0,feedbackLow=0}
local trace,decisions,integrated={},{},{x=0,y=0,z=0};local lastTelemetryAt=baseline.finishedAt
local function abort(r)if not abortReason then abortReason=tostring(r)end end
local function record(s)local c,n=s.corner,tonumber(s.appliedSequence);if lastSeq[c]and n and n<lastSeq[c]then abort("pod "..c.." applied-sequence regression")end;if n then lastSeq[c]=n end;latest[c],lastAt[c]=s,os.epoch("utc");if not clean(s)then abort("pod "..c.." reported a transport/apply fault")end;if phase=="precheck"and applied(s,0,RPM)then preSeen[c]=true end;if applied(s,HIGH,RPM)then highSeen[c]=true;if inHover then hoverHigh[c]=true end end;if applied(s,LOW,RPM)then lowSeen[c]=true;if inHover then hoverLow[c]=true end end;if phase=="shutdown"and applied(s,0,0)then zeroSeen[c]=true end end
local function receive()while active do local e,_,ch,_,m=os.pullEvent();if e=="guarded_hover_done"then return end;if e=="modem_message"and ch==STATUS and type(m)=="table"and m.protocol==PROTOCOL and m.session==session and CORNER_SET[m.corner]then record(m)end end end
local function send(kind)sequence=sequence+1;modem.transmit(CONTROL,STATUS,frame(session,sequence,os.epoch("utc"),kind));frames=frames+1 end
local function runPhase(seconds,kind,name,stop)phase=name;local period=math.floor(1000/RATE);local stopAt,nextAt=os.epoch("utc")+seconds*1000,os.epoch("utc");while os.epoch("utc")<stopAt do if abortReason then return false end;if stop and stop()then return true end;send(kind);nextAt=nextAt+period;local wait=nextAt-os.epoch("utc");if wait>0 then sleep(wait/1000)end end;return true end
local function fresh(power,rpm,seen)local now=os.epoch("utc");for _,c in ipairs(CORNERS)do local s=latest[c];local age=lastAt[c]and now-lastAt[c]or math.huge;if not seen[c]or age>POD_AGE or not clean(s)or not applied(s,power,rpm)then return false,c end end;return true end
local function seen(t)for _,c in ipairs(CORNERS)do if not t[c]then return false,c end end;return true end
local function update(s)
 local interval=s.finishedAt-lastTelemetryAt;local dt=math.max(0,interval/1000);lastTelemetryAt,latestTelemetryAt=s.finishedAt,s.finishedAt;integrated.x=integrated.x+s.linearVelocity.x*dt;integrated.y=integrated.y+s.linearVelocity.y*dt;integrated.z=integrated.z+s.linearVelocity.z*dt
 local r=p0 and s.position and{x=s.position.x-p0.x,y=s.position.y-p0.y,z=s.position.z-p0.z}or{x=integrated.x,y=integrated.y,z=integrated.z};local m,violation=evaluate(s,q0,r);if interval>MAX_SAMPLE+250 then violation=violation or"CC:Sable telemetry interval stale"end;latestMetrics=m
 data.count=data.count+1;data.maxSampleMs=math.max(data.maxSampleMs,s.elapsedMs);data.minRise=math.min(data.minRise,m.rise);data.maxRise=math.max(data.maxRise,m.rise);data.maxVerticalSpeed=math.max(data.maxVerticalSpeed,m.verticalSpeed);data.maxHorizontalDisplacement=math.max(data.maxHorizontalDisplacement,m.horizontalDisplacement);data.maxHorizontalSpeed=math.max(data.maxHorizontalSpeed,m.horizontalSpeed);data.maxTotalSpeed=math.max(data.maxTotalSpeed,m.totalSpeed);data.maxAngularSpeed=math.max(data.maxAngularSpeed,m.angularSpeed);data.maxTiltDegrees=math.max(data.maxTiltDegrees,m.tiltDegrees)
 trace[#trace+1]={t=(s.finishedAt-started)/1000,phase=phase,rise=m.rise,vy=m.verticalVelocity,hs=m.horizontalSpeed,speed=m.totalSpeed,tilt=m.tiltDegrees,angular=m.angularSpeed}
 if phase=="lift"and not data.triggerReason then data.triggerReason=trigger(m)end;if phase=="brake"then data.brakeSamples=data.brakeSamples+1;data.brakeFinalVelocity=m.verticalVelocity end
 if inHover and targetRise then data.hoverSamples=data.hoverSamples+1;if stable(m,targetRise)then stableSince=stableSince or s.finishedAt;if s.finishedAt-stableSince>=STABLE_MS then data.stableWindowSeen=true end else stableSince=nil end end;return violation
end
local function telemetry()while active do if phase~="shutdown"then local s=sample(sublevel);if not sampleValid(s)then abort("CC:Sable telemetry invalid or stale")else local v=update(s);if v and phase~="idle"then abort(v)end end;local now=os.epoch("utc");if phase~="idle"then for _,c in ipairs(CORNERS)do if lastAt[c]and now-lastAt[c]>POD_AGE then abort("pod "..c.." status became stale")end end end end;sleep(.05)end end
local function runHover()
 inHover,phase=true,"hover";targetRise=assert(latestMetrics and latestMetrics.rise,"hover target unavailable");for slot=1,math.floor(HOVER*1000/SLOT_MS)do if abortReason then return false end;if not latestMetrics or not latestTelemetryAt or os.epoch("utc")-latestTelemetryAt>MAX_SAMPLE+250 then abort("controller telemetry stale")return false end
  local kind,reason=choose(latestMetrics,targetRise,slot);if kind=="high"then data.highSlots=data.highSlots+1 else data.lowSlots=data.lowSlots+1 end;if reason=="downward_speed"or reason=="below_target"then data.feedbackHigh=data.feedbackHigh+1 end;if reason=="upward_speed"or reason=="above_target"or reason=="absolute_high_inhibit"then data.feedbackLow=data.feedbackLow+1 end;decisions[#decisions+1]={slot=slot,kind=kind,reason=reason,rise=latestMetrics.rise,vy=latestMetrics.verticalVelocity};phase=kind=="high"and"hover_high"or"hover_low"
  local stopAt,nextAt=os.epoch("utc")+SLOT_MS,os.epoch("utc");while os.epoch("utc")<stopAt do if abortReason then return false end;send(kind);nextAt=nextAt+math.floor(1000/RATE);local wait=nextAt-os.epoch("utc");if wait>0 then sleep(wait/1000)end end
 end;inHover=false;return true
end
local function shutdown()inHover,phase=false,"shutdown";local stopAt=os.epoch("utc")+SHUTDOWN*1000;while os.epoch("utc")<stopAt do pcall(send,"shutdown");sleep(.1)end end
local function run()
 print("Precheck: zero-ion/RPM-64 and four clean acknowledgements.");if not runPhase(PRECHECK,"spin","precheck")then error(abortReason or"precheck aborted",0)end;local ok,c=fresh(0,RPM,preSeen);if not ok then error("fresh precheck not confirmed for "..c,0)end
 print("Lift: 3/15 to early trigger.");if not runPhase(LIFT_LIMIT,"high","lift",function()return data.triggerReason~=nil end)then error(abortReason or"lift aborted",0)end;if not data.triggerReason then error("lift trigger not reached",0)end
 local brakeAt=os.epoch("utc");print("Brake: 2/15 until upward speed is controlled.");if not runPhase(BRAKE_LIMIT,"low","brake",function()return os.epoch("utc")-brakeAt>=BRAKE_MIN*1000 and data.brakeSamples>=5 and latestMetrics and latestMetrics.verticalVelocity<=BRAKE_VY end)then error(abortReason or"brake aborted",0)end;if not latestMetrics or latestMetrics.verticalVelocity>BRAKE_VY then error("2/15 braking did not control upward speed",0)end
 print("Hover: guarded duty cycle with feedback overrides.");if not runHover()then error(abortReason or"guarded hover aborted",0)end;local a,b=seen(hoverHigh);if not a then error("hover 3/15 not confirmed for "..b,0)end;a,b=seen(hoverLow);if not a then error("hover 2/15 not confirmed for "..b,0)end;if not data.stableWindowSeen then error("two-second stable hover window not observed",0)end
end
local function sender()local ok,e=pcall(run);if not ok then runError=tostring(e)end;print((runError or abortReason)and"Proof/safety failed; exact-zero shutdown."or"Hover proof complete; exact-zero shutdown.");shutdown();sleep(1);local now=os.epoch("utc");for _,c in ipairs(CORNERS)do local s,age=latest[c],nil;age=lastAt[c]and now-lastAt[c]or math.huge;if not zeroSeen[c]or age>POD_AGE or not applied(s,0,0)or(tonumber(s.appliedSequence)or-1)~=sequence then shutdownError="fresh zero shutdown not confirmed for "..c;break end end;active=false;os.queueEvent("guarded_hover_done")end
local ok,e=pcall(parallel.waitForAll,sender,receive,telemetry);if not ok then runError=runError or tostring(e);pcall(shutdown);active=false end;pcall(modem.close,STATUS)
local failure=runError or abortReason or shutdownError;local lines={"WIRED FRAME ZERO-TILT GUARDED HOVER PROOF","session="..session,"modem="..tostring(modemName),"mode="..MODE,"safety=FCS_DEV_GUARDED_HOVER","sublevel_source="..tostring(sublevelSource),"position_source="..data.positionSource,"high_power="..HIGH,"low_power="..LOW,"fallback_power="..FALLBACK,"slot_ms="..SLOT_MS,"nominal_high_slots=1/4","hover_seconds="..HOVER,"target_rise="..tostring(targetRise),"abort_max_rise="..MAX_RISE,"high_inhibit_rise="..HIGH_INHIBIT_RISE,"frames_sent="..frames,"final_sequence="..sequence,"telemetry_samples="..data.count,"telemetry_max_sample_ms="..data.maxSampleMs,"telemetry_min_rise="..data.minRise,"telemetry_max_rise="..data.maxRise,"telemetry_max_vertical_speed="..data.maxVerticalSpeed,"telemetry_max_horizontal_displacement="..data.maxHorizontalDisplacement,"telemetry_max_horizontal_speed="..data.maxHorizontalSpeed,"telemetry_max_total_speed="..data.maxTotalSpeed,"telemetry_max_angular_speed="..data.maxAngularSpeed,"telemetry_max_tilt_degrees="..data.maxTiltDegrees,"trigger="..tostring(data.triggerReason),"brake_samples="..data.brakeSamples,"brake_final_vy="..tostring(data.brakeFinalVelocity),"hover_samples="..data.hoverSamples,"high_slots="..data.highSlots,"low_slots="..data.lowSlots,"feedback_high_slots="..data.feedbackHigh,"feedback_low_slots="..data.feedbackLow,"stable_window_seen="..tostring(data.stableWindowSeen)}
if runError or abortReason then lines[#lines+1]="run_error="..tostring(runError or abortReason)end;if shutdownError then lines[#lines+1]="shutdown_error="..shutdownError end
for i,d in ipairs(decisions)do lines[#lines+1]=string.format("decision=%d slot=%d kind=%s reason=%s rise=%.6f vy=%.6f",i,d.slot,d.kind,d.reason,d.rise,d.vy)end;for i,t in ipairs(trace)do lines[#lines+1]=string.format("trace=%d t=%.3f phase=%s rise=%.6f vy=%.6f hspeed=%.6f speed=%.6f tilt=%.6f angular=%.6f",i,t.t,t.phase,t.rise,t.vy,t.hs,t.speed,t.tilt,t.angular)end
local overall,aggregate=failure==nil,0;for _,c in ipairs(CORNERS)do local s=latest[c];local received=s and tonumber(s.received)or 0;aggregate=aggregate+received;local pass=s and preSeen[c]and highSeen[c]and lowSeen[c]and hoverHigh[c]and hoverLow[c]and zeroSeen[c]and received==frames and clean(s)and(tonumber(s.appliedSequence)or-1)==sequence and applied(s,0,0);if not pass then overall=false end;lines[#lines+1]=string.format("%s recv=%d missing=%s dup=%s order=%s invalid=%s applied=%s expired=%s errors=%s fallbacks=%s fallback_stops=%s precheck=%s high=%s low=%s hover_high=%s hover_low=%s shutdown=%s ion=%s rpm=%s tilt=%s result=%s",c,received,tostring(s and s.missing or"nil"),tostring(s and s.duplicates or"nil"),tostring(s and s.outOfOrder or"nil"),tostring(s and s.invalid or"nil"),tostring(s and s.appliedSequence or"nil"),tostring(s and s.expiredBeforeApply or"nil"),tostring(s and s.applyErrors or"nil"),tostring(s and s.fallbackCount or"nil"),tostring(s and s.fallbackStops or"nil"),tostring(preSeen[c]==true),tostring(highSeen[c]==true),tostring(lowSeen[c]==true),tostring(hoverHigh[c]==true),tostring(hoverLow[c]==true),tostring(zeroSeen[c]==true),tostring(s and s.appliedIonPower or"nil"),tostring(s and s.appliedPropRpm or"nil"),tostring(s and s.appliedTiltDegrees or"nil"),pass and"PASS"or"FAIL")end
lines[#lines+1]="aggregate_verified_deliveries="..aggregate;lines[#lines+1]="overall="..(overall and"PASS"or"FAIL");local f=fs.open(RESULT,"w");if not f then error("unable to write "..RESULT,0)end;f.write(table.concat(lines,"\n"));f.close();print("Result: "..(overall and"PASS"or"FAIL"));print("Report written to "..RESULT);if not overall then error("zero-tilt guarded hover proof failed",0)end
