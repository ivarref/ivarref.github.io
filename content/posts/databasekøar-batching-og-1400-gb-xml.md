---
draft: true
title: Databasekøar, batching og 1400 GB XML
---

## Bakgrunn

Eg hadde sagt ja til å forbetra eit legacysystem. Kor vanskeleg kunne det vera?
Eg hadde fått det for meg at det var
snakk om rundt 70 GB XML det skulle prosessera. Det viste seg å vera
1400 GB XML. Kjeldekoden var skriven i Python 2 (end of life i 2020), hadde ingen testar,
ingen spesifiserte avhengigheiter og innehaldt i tillegg rundt ti tusen linjer
med SQL, primært i form av prosedyrer. Koden, dvs. importen av XML,
hadde ei eksisterande køyretid på fleire månadar. Sluttresultatet skulle vera ein PostgreSQL
database med rundt 80 tabellar. Det var med andre ord eit _interessant_ prosjekt.

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
[timeout omlag rundt 924.6 sekund](https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt).

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

La oss anta at ein har følgande tabell:

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
for ei gitt rad med éin nettverksrunde.

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
saman med storleiken antall items i ein batch.

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
og `ioping` ([kjelde](https://www.brendangregg.com/systems-performance-2nd-edition-book.html)).
Lesing var raskare på mi maskin, medan skriving var raskare på serveren.

