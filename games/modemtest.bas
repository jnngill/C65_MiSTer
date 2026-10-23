10 rem c65 modem test, 911210 rom, 9600 baud 8n1
20 close 2:open 2,2,0,chr$(14)+chr$(0)
30 print"c65 modem test":print"sending at"
40 s$="at"+chr$(13):gosub 300
50 t=ti
60 gosub 200:if ti-t<180 then 60
70 print:print"terminal mode, run/stop to quit"
80 get k$:if k$<>"" then s$=k$:gosub 300
90 gosub 200:goto 80
200 get#2,a$:if a$="" then return
210 c=asc(a$):if c=10 then return
220 if c>=193 and c<=218 then c=c-128
230 if c>=97 and c<=122 then c=c-32
240 print chr$(c);:return
300 for i=1 to len(s$):c=asc(mid$(s$,i,1))
310 if c>=193 and c<=218 then c=c-96
320 if c=20 then c=8
330 print#2,chr$(c);:next:return
