---
draft: true
title: Databasekøar, batching og 1400 GB XML
---

## Bakgrunn

Eg hadde sagt ja til å forbetra hastigheita på eit legacysystem. Kor vanskeleg kunne det vera?

Eg hadde fått det for meg at det var
snakk om rundt 70 GB XML det skulle prosessera. Det viste seg å vera
1400 GB XML. Kjeldekoden var skriven i Python 2 (end of life i 2020), hadde ingen testar,
ingen spesifiserte avhengigheiter og innehaldt i tillegg rundt ti tusen linjer
med SQL, primært i form av prosedyrer.

Koden, som skulle gjera ein import av XML-en,
hadde ei køyretid på fleire månadar.

Sluttresultatet skulle vera ein PostgreSQL
database med rundt 80 tabellar. Det var med andre ord det ein kunne kalla _interessant_ prosjekt.

## Kviss

Kor lang tid tek det å utføra `SELECT version()` frå ein backend til ein PostgreSQL-instans?

Tenk på det. Tenk på det litt til.

Og ørlite til ja …

Okei. Det får duge. Takk.

## Svar kviss

Svaret er: det kjem an på.

For det fyrste kan det oppstå nettverksfeil.
Er ein maks uheldeg
kan backenden ha motteke ein TCP acknowledgement og deretter at tilkoblinga vert droppa utan at backenden
får beskjed. Då endar ein opp med
[å venta i all evigheit](https://blog.cloudflare.com/when-tcp-sockets-refuse-to-die/).

Ein anna nettverksfeilcase er at tilkoblinga vert droppa før TCP ACK er kome.
Då får ein ein
[timeout på omlag 924.6 sekund](https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt).

Dersom køyrer docker swarm, kan
[tilkoblinga fryse etter 15 minutt](https://github.com/moby/moby/issues/37466#issuecomment-405537713).

Desse problema kan ein handsama ved å setja socket timeout (jdbc, psycopg) og/eller keep alive.
Eg har snakka om dette [her](https://www.youtube.com/watch?v=jQi_D4cosr0).

La oss anta at det ikkje er noko nettverksfeil:

```
PostgreSQL køyrande lokalt:  40 microsekund (1x) (mi maskin, MacBook Air M3)
Azure Container App:        160 microsekund (4x)
lima-vm/docker for mac:     200 microsekund (5x)

=> RTT: Round Trip Time. Gjennomsnitt av 100 000 målingar.
```

Ein ser med andre ord at eit produksjonsoppsett kan vera fire gonger treigare enn
lokalt oppsett, primært grunna nettverket.

Om ein ynskjer eit lokalt oppsett _med nettverkstreigheit_, kan ein f.eks. nytta
[traffic control](https://jvns.ca/blog/2017/04/01/slow-down-your-internet-with-tc/) (linux)
eller 
[packet filter & traffic shaper](https://serverfault.com/questions/725030/traffic-shaping-on-osx-10-10-with-pfctl-and-dnctl)
(mac).


## UPSERTs: atomisk innleggjelse eller oppdatering av tabellverdiar

La oss anta at ein har fylgjande tabell:

```sql
CREATE TABLE s.shopping_list(item_name TEXT PRIMARY KEY,
                             cnt       BIGINT NOT NULL); 
                             -- cnt = count = antall ein skal kjøpa
```

I førre avsnitt såg ein at nettverksrundetida, round trip time (RTT), er sentralt
for kor raskt ei spørring går. Det vanleg å skilja mellom `UPDATEs`
og `INSERTs` på backend-sida. Ein kan ofte sjå fylgjande kode:

```python
existing_cnt = SELECT cnt from s.shopping_list WHERE item_name = ...
if existing_cnt:
    UPDATE s.shopping_list SET cnt = ? WHERE item_name = ?
else:
    INSERT INTO s.shopping (item_name, cnt) VALUES (?, ?)
```

Dette ovanfor krever to nettverksrundar. Det finst ein raskare måte:

`UPSERTs`, som tyder `INSERT` or `UPDATE`, er støtta av ulike databasar.
For PostgreSQL ser eksempelet over slik ut:

```sql
INSERT INTO s.shopping_list (item_name, cnt) VALUES (?, ?)
ON CONFLICT (item_name) DO UPDATE SET
cnt = s.shopping_list.cnt + EXCLUDED.cnt;

-- dersom ein ikkje vil gjera UPDATE og unngå Unique Violation Constraint:
-- ON CONFLICT (item_name) DO NOTHING
```

`EXCLUDED.<kolonnenamn>` tyder det ein sender inn som input.
`s.shopping_list.cnt` referer til det som allereie ligg i databasen.
Det ein gjer her er å leggja inn eller plussa på eksisterande verdi
for ei gitt rad i éin nettverksrunde.

## Batching: raskare innleggjelse i databasen

I Python kan ein skriva fylgjande kode:

```python
cursor = conn.cursor()
sql = 'INSERT INTO s.shopping_list (item_name, cnt) VALUES (%s, %s)'
      # Kan også ha ON CONFLICT (item_name) ... 

cursor.execute(sql, ('Filterkaffi', 1))
cursor.execute(sql, ('H-mjølk', 4)) # Treng mykje mjølk til å laga graut
                                    # og ikkje minst til å ha i kaffien
```

Kvar `cursor.execute` gjer ein full nettverksrunde (round trip time), og dette tek unødvendig
mykje tid. Batchversjonen i Python ser slik ut:

```python
cursor.executemany(sql, [('Filterkaffi', 1), ('H-mjølk', 4)])
```

Tilsvarande kode i vanleg Java
kan nytta
[java.sql.PreparedStatement](https://docs.oracle.com/en/java/javase/21/docs/api/java.sql/java/sql/PreparedStatement.html):

```java
String sql = "INSERT INTO s.shopping_list (item_name, cnt) VALUES (?, ?)";
PreparedStatement pstmt = conn.prepareStatement(sql);

pstmt.setString(1, "Filterkaffi");
pstmt.setInt(2, 1);
pstmt.addBatch();

pstmt.setString(1, "H-mjølk");
pstmt.setInt(2, 4); // 4 x h-mjølk til grauten
pstmt.addBatch();

pstmt.executeUpdate();
```

Med batching unngår ein full nettverksrunde for kvar rad. Ein sender i staden
kvar `INSERT` samla i ein batch.

Eit `prepared statement` tyder at databaseserveren parser og planlegg queryet
og tek vare på resultatet i serversesjonen. I [psycopg](https://psycopg.org),
Python sin PostgreSQL drivar,
vert det automatisk gjort `prepared statements` dersom eit query har
[køyrd fleire enn 5 gonger](https://www.psycopg.org/psycopg3/docs/advanced/prepare.html).
Det same gjeld den
[PostgreSQL JDBC drivaren](https://jdbc.postgresql.org/documentation/server-prepare/#server-prepared-statements)
for Java.

## PostgreSQL: COPY protokollen

PostgreSQL har, i tillegg til prepared statements, ein eigen
[copy protokoll](https://www.postgresql.org/docs/current/sql-copy.html).
Den er enno raskare enn en batching.
`psycopg` støttar denne protokollen, og bruken av det ser slik ut:

```python
copy_sql = 'COPY s.shopping_list (item_name, cnt) FROM STDIN'
with cursor.copy(copy_sql) as copy:
  copy.write_row(('Filterkaffi', 1))
  copy.write_row(('H-mjølk', 4)) # Ein lyt ha mjølk. Elles vert det kaffimage
```

Ei ulempe med COPY-protokollen er at den ikkje støttar konflikthandsaming.
Det vil seia at den ikkje har noko konsept tilsvarande `UPSERTs`. Dersom
ein legg inn ein duplikat i COPY-protokollen, vil transaksjonen feila.

## Ytelsestest i Azure

`INSERTs` med 100 sekvensielle transaksjonar à 1000 rader, totalt 100 000 rader:

```
COPY:     10 micros/rad (1x)
Batch:    60 micros/rad (6x)
Single:  180 micros/rad (18x)
```

I denne testen var single `INSERTs` 18 gonger treigare enn `COPY` og
3 gonger treigare enn med batching. Merk at ein her nytta ein 100 sekvensielle
transaksjonar. Dette tyder at ein batch fekk ei øvre grense på 1 000 items
som så vart skrive til databasen og ein laut venta på ein nettverksrunde.
Dermed vil den relative vinsten med batching auka
saman med antall på items i ein batch.

## IO vs CPU

På dette stadiet i prosjektet hadde eg kun utvikla lokalt på mi bærbare datamaskin,
ein MacBook Air M3.
Programmet hadde vorte ganske mykje raskare enn det var opprinneleg.

![Dell PowerEdge R6525 vs MacBook Air M3 2024](/images/dell_vs_macair.png)

Det var no på tide å køyra det på produksjonsserveren: ein Dell PowerEdge R6525 server
med 32 kjernar, 2 TB RAM og eit par NVMe diskar som kosta over hundre tusen per stykk.
"Dette er ikkje ein vanleg dødeleg server," som ein kollega uttrykte det.

Og kvar køyrde programmet raskast? Jodå, på min lokale bærbar. Eg fekk tilløp til panikk.

Ein kunne ikkje skulda på nettverket: på serveren køyrde PostgreSQL databasen lokalt.

Eg samanlikna diskytelsen på serveren med bruk av kommandoar som
`dd if=/dev/zero of=out1 bs=1024k count=1000 oflag=direct`
og `ioping`.
Lesing var raskare på mi maskin, medan skriving var raskare på serveren.

Etter å ha kikka på ytelsen med [pgtop](https://pg_top.gitlab.io/), vart det etterkvart
klårt at dette var ei CPU-bound oppgåve. Ein kan òg nytta verktøy som `mpstat -P ALL`.
Då såg ein at `iowait`, dvs. venting på disk, var lågt, medan CPU-bruk var høgt.
Slike verktøy og analysemetodar er godt skildra i boka
[Systems performance: Enterprise and the Cloud](https://www.brendangregg.com/systems-performance-2nd-edition-book.html)
av Brendan Gregg.

Ei endeleg stadfesting fekk eg då eg køyrde det på min gamle linuxbærbar.
Både disklesing og -skriving var treigare der enn på serveren,
likevel gjekk det raskare enn på den gamle bærbaren. Og vifta gjekk i taket.
CPU-en på min gamle linuxbærbar var kraftigare enn den litt eldre "superserveren"
med 2 TB RAM.

MacBook Air (M*) er som kjent viftelaus, så eg hadde rett og slett ikkje tenkt
mykje på CPU-bruk, særleg ettersom bruken skjedde på ein-to av åtte tilgjengelege kjernar.

Uansett hadde det vore klårt frå byrjinga at ein burde paralellisera arbeidet:
Det er greit å nytta dei CPU-ane ein faktisk har.

## Parallelliseringskviss

Kor lang tid tek det å utføra fylgjande transaksjon?

```sql
UPDATE s.shopping_list SET cnt = cnt*2 WHERE item_name = 'Filterkaffi'
UPDATE s.shopping_list SET cnt = cnt*2 WHERE item_name = 'H-mjølk'

```

Tenk på det. Ikkje altfor for hardt, ikkje altfor lett, men sånn passe.

Var det ein lurekviss? Tja. Svaret er uansett som på førre kviss:
det kjem an på. Denne gongen skal det handla
om kva anna som skjer samstundes i databasen.

La oss seia at annan transaksjon held ein lås på rada med "H-mjølk".
Då lyt ein nødvendigvis venta til den har committa før ein får gjort noko.
Men kva om så den andre transaksjonen ynskjer å skriva til rada med "Filterkaffi",
den rada som denne transaksjonen held ein lås på,
før den committer? Då får ein ein deadlock. Dette er meir utfyllande forklart i
[denne artikkelen](https://www.cybertec-postgresql.com/en/postgresql-understanding-deadlocks/).

Poenget er forhaldsvis enkelt:
det er ikkje nødvendigvis uproblematisk å skriva batchar av data til same tabell frå
fleire prosessar samstundes. Blant anna deadlocks og lange ventetider kan oppstå.
Kan parallelliseringa gjerast enklare, dvs. utan å måtta tenkja på rekkefylgje
og låsing?

## Parallelliseringsstrategi

Som eg skreiv i byrjinga så var det rundt 80 tabellar i dette systemet.
Ein XML "item" skulle enda opp i 80 ulike tabellar.

Ein naiv parallelliseringsstrategi ville sjå slik ut:
```
Process 1: item-1 => tbl_1, tbl_2 … tbl_80
Process 2: item-2 => tbl_1, tbl_2 … tbl_80
Process 3: item-3 => tbl_1, tbl_2 … tbl_80
```

Dette ovanfor, som eg argumenterte for tidlegare, vil lett kunne skapa deadlocks
og lange ventetider. I staden er det betre å laga eit køsystem.
Éin kø (transaksjon) skriv til éin tabell. Ingen av køane skriv til dei same tabellane.
Slik ser ei enkel skisse ut:

```
Køsystem
Process/kø 1: item-1, item-2, item-3 => tbl_1 + => kø_2
Process/kø 2: item-1, item-2, item-3 => tbl_2 + => kø_3
Process/kø 3: item-1, item-2, item-3 => tbl_2 + => kø_4
```

Tanken her er at ein kø i tillegg til å skriva til ein tabell,
òg sender XML-itemet vidare til neste kø.
Her er det, som du vonleg ser, gode moglegheiter for batching.

Litt forenkla kan ein seia at total køyretid for systemet
vert:

`treigaste kø * antall items`

Korleis lagar ein eit slikt køsystem?

## Concurrent batchkø

Ein ynskjer fylgjande eigenskapar til køsystemet:

* Transaksjonell og del av same database.
* Fleire consumers, også for same kø.
* Feilhandsaming: rollback og eventuelt retry.
* Minst mogleg styr.

Med "minst mogleg styr", mitt favorittpunkt,
meinar eg at ein bør unngå
ting som `compare-and-swap`, venting på låsar & deadlocks, uturvande koordinering
mellom prosessar og liknande.

SQL har desse eigenskapane i form av `FOR UPDATE SKIP LOCKED` og `SAVEPOINT`.

I tillegg treng ein òg ein enkel tabell for å halda styr på kø-items.
Eksempelvis:

```sql
CREATE TABLE batch_queue(id         PRIMARY KEY,
                         queue_name TEXT NOT NULL,
                         status     TEXT NOT NULL, 
                         payload    TEXT NOT NULL)
```
## SELECT … FOR UPDATE SKIP LOCKED

`SELECT … FOR UPDATE SKIP LOCKED` er som orda tilseier:

* Ein selecter rader (`SELECT …`).
* Seier i frå til databasen at desse kjem til å verta oppdatert (`FOR UPDATE`).
  Dette tyder at ein låser radene.
* Ignorerer allereie låste rader.

Dette vert gjort i éin operasjon. Det er då ikkje nokon sjanse for at det vert
låsekonflikt eller -venting mellom ulike transaksjonar.

## SAVEPOINTs

La oss seie fylgjande psuedokode køyrer:

```
Hent køjobb: SELECT * FROM batch_queue FOR UPDATE SKIP LOCKED ...
Køjobb: INSERT INTO tbl_1 => OK
        INSERT INTO tbl_2 => 💥UniqueConstraintViolation💥
        => Rulle attende alt?
```

Skal ein då rulle attende alt? Då mistar ein låsen for batchkø-radene. Ein annan
consumer kan då ta radene og få same feil på nytt. Skal ein committe?
Då får ein ein delvis utført køjobb. Ein ynskjer ingen av delene.

Det er her [SAVEPOINT](https://www.postgresql.org/docs/current/sql-savepoint.html)s kjem
inn i biletet. Det er òg kjent under namna `nested transactions` og `subtranction`.

> A savepoint is a special mark _inside a transaction_ that allows all commands that are executed
> after it was established to be rolled back,
> restoring the transaction state to what it was at the time of the savepoint.

Sitat frå PostgreSQL-dokumentasjonen og med mi utheving:
med `SAVEPOINTs` kan ein rulla attende _ein del_ av ein transaksjonen.

## Concurrent batchkø

Psuedokode for ein concurrent batchkø med `SAVEPOINTs` kan sjå slik ut:

```
SELECT * FROM batch_queue WHERE status='INIT' FOR UPDATE SKIP LOCKED ...
SAVEPOINT pre_queue_consumer_fn
try:
  køjobb funksjon: INSERT INTO tbl_1 OK
  køjobb funksjon: INSERT INTO tbl_2 💥UniqueConstraintViolation💥
  UPDATE batch_queue status=’DONE’ WHERE ...
except Exception:
  ROLLBACK TO pre_queue_consumer_fn 
  UPDATE batch_queue SET status=’ERROR’ WHERE …
COMMIT
```

Her nyttar ein `SAVEPOINTs` for å kunne gjera to ting: rulla attende det som har skjett
inne i køjobbfunksjonen _samstundes_ som ein framleis held på dei låste radene i batchkøtabellen.
Dette gjev oss dei eigenskapane me ynsker oss:

* Ein kan ha fleire consumers per kø om ein ynskjer det. Consumers vil ikkje gå i beina på
kvarandre, òg om ein skulle rulla attende.

* Ein får rulla attende nøyaktig det ein ynskjer, samstundes som ein ikkje slepp batchkølåsen.
  Det bør vera grei skuring å i tillegg leggja til retry. Om ein har henta ut ti køitems,
  kan ein f.eks. prøva ein og ein på nytt i separate transaksjonar.

* "Minst mogleg styr." Databasen gjer all koordineringa for oss. Konsumentar kan køyra på
  heilt separate prosessar eller maskiner. Det er godt å ikkje trenga å bekymra seg over eigne
  moglegheiter for race conditions og liknande.

## Resultat

Prosjektet kom etterkvart i mål. Det vart rundt 30 køar og 80 køkonsumentar.
Det vart ingen inter process communication eller moglegheiter for race conditions.
Koden er framleis mogleg å resonnera om.

Hovudmålet for prosjektet vart nådd: køyretida gjekk frå manadar til éin dag!

Med det er det berre å avslutta med [Olav H](https://www.nrk.no/kultur/_det-er-den-draumen_-er-norges-beste-dikt-1.13140034):

_Det er den draumen me alle – eller i det minste sume av oss – ber på:\
at noko vedunderleg skal skje\
at vekes- og sletteimporten skal køyra før jol\
at det må skje\
at mogleg fråvær av indeksar ikkje skal skapa problem\
at snøggleiken ikkje går dramatisk ned ved oppdatering\
at tidi per importeining held seg konstant\
at me ei morgonstund skal dukka ned\
i data me ikkje har visst um_

***

❤️ Takk til alle som bidrog! ❤️

[//]: # (_Takk til ... for innspel, kommentarar og hjelp._)