PostgreSQL Recovery 실습
===

PostgreSQL은 사고 상황에서 데이터 무결성을 보장하기 위해 [WAL(Write-Ahead Logging)][wal-intro]을 작성합니다.

트랜잭션 처리 중 시스템이 내려간 상황을 상상해봅시다. 트랜잭션을 커밋했어도 데이터가 버퍼에만 쓰이고 아직 디스크에는 쓰이지 않았을 수 있습니다. 이런 상황에서 시스템이 내려가면 변경사항을 잃어버립니다. PostgreSQL은 변경사항을 쓰기 전에 항상 로그를 작성합니다. 이를 이용하면 앞서 말한 상황이 일어났을 때 로그를 보고 아직 쓰이지 않은 변경사항을 재실행(redo)하여 사고를 복구하고 데이터 무결성을 유지할 수 있습니다.

이 글에서는 Docker를 사용해서 트랜잭션 커밋 전후 시점의 스냅샷 이미지를 만든 후
data 파일은 커밋 전, log 파일은 커밋 후 시점에서 임의로 가져와서
failure 상황의 디스크 이미지를 가장한 후 복구가 잘 수행되는지 확인해볼 것입니다.

**실습에 사용하는 파일들:**

- [**init.sql**](./init.sql)
    
    ```sql
    CREATE TABLE article (
      id integer primary key,
      title varchar(255),
      created_at timestamp not null
    );
    INSERT INTO article (id, title, created_at) VALUES (
      1, 'hello', now()
    );
    INSERT INTO article (id, title, created_at) VALUES (
      2, 'initialized!', now()
    );
    ```
    
- [**Dockerfile.base**](./Dockerfile.base)
    
    ```docker
    FROM postgres:15-alpine
    
    ENV POSTGRES_HOST_AUTH_METHOD trust
    # 기본값 디렉토리는 volume에 연결되므로 UnionFS에 쓰이지 않아서 커밋했을 때
    # 이미지에 파일이 기록되지 않습니다. 따라서 별도 디렉토리를 만들어줍니다.
    ENV POSTGRES_INITDB_WALDIR /var/lib/pg-wal
    ENV PGDATA /var/lib/pg-data
    
    RUN mkdir -p $POSTGRES_INITDB_WALDIR
    RUN mkdir -p $PGDATA
    
    # `article` 테이블과 1, 2번 article을 미리 만들어서 넣어줍니다.
    COPY init.sql /docker-entrypoint-initdb.d/
    ```
    
- [**Dockerfile.crashed**](./Dockerfile.crashed)
    
    ```docker
    FROM dbslab-after-commit AS committed
    
    FROM dbslab-before-commit
    
    # copy ONLY WAL files
    COPY --from=committed $POSTGRES_INITDB_WALDIR $POSTGRES_INITDB_WALDIR
    ```
    

## 준비

### Step 1) PostgreSQL 서버 실행시키기

우선 `Dockerfile.base`를 사용해서 `dbslab-base` 라는 이름으로 PostgreSQL 서버 이미지를 만듭니다.

```console
$ docker build -f Dockerfile.base -t dbslab-base
```

해당 이미지에는 다음 디렉토리를 데이터, WAL 디렉토리로 사용하도록 설정되어 있습니다.

- 데이터 디렉토리: `/var/lib/pg-data`
- WAL 디렉토리: `/var/lib/pg-wal`

또한 article 테이블과 1, 2번 행이 포함되어 있습니다.

앞서 만든 이미지를 가지고 `dbslab` 이라는 이름으로 서버 컨테이너를 실행시킵니다.

```console
$ docker run -d --name dbslab dbslab-base
```

이제 `docker exec` 명령을 통해 컨테이너에서 명령을 실행시키거나 쉘에 접속할 수 있습니다.

```console
# ash 쉘 접속
$ docker exec -it dbslab /bin/ash

# psql 쉘 접속
$ docker exec -it dbslab psql -U postgres
```

article 테이블과 2개의 article이 이미 만들어져 있습니다.

```sql
SELECT * FROM article;
```

```
 id |          title           |         created_at
----+--------------------------+----------------------------
  1 | hello                    | 2022-12-01 10:09:17.608912
  2 | initialized!             | 2022-12-01 10:09:17.609587
(2 rows)
```

### Step 2) 트랜잭션 실행 중간 시점, 커밋 이후 시점 스냅샷 이미지 만들기

다음과 같이 두 article을 삽입하는 하나의 트랜잭션을 수행할 것입니다.

```
1. Transaction begin
2. INSERT 3rd-article
-------- (A) --------
3. INSERT 4th-article
4. Transaction commit
-------- (B) --------
```

이번 실습에서는 로그는 모두 stable storage에 쓰였지만 데이터가 모두 output되지 않은 채 시스템이 내려간 상황을 모사할 것입니다. 정확히는 3rd-article은 output 됐지만 4th-article은 output 되지 않은 상황인 (A) 시점에 시스템이 내려간 상황입니다.

우선 앞서 실행한 데이터베이스에 접속하고 트랜잭션을 수행합니다.

```console
$ docker exec -it dbslab psql -U postgres
```

```sql
BEGIN;

-- 3rd article을 생성하되 아직 커밋하지 않습니다.
INSERT INTO article (id, title, created_at) VALUES (
  3, concat('3rd article - txid = ', txid_current()), now()
);

-- 추후 WAL 분석을 위해 현재 트랜잭션 ID를 기억해둡니다.
SELECT txid_current();

-- 주의: 아직 psql 세션을 종료하지 마세요!
```

```
 txid_current
--------------
          739
(1 row)
```

다른 창에서 현재 컨테이너의 상태를 `dbslab-before-commit` 이라는 이름의 이미지로 만듭니다. 이 이미지는 (A) 시점의 스냅샷일 것입니다.

```console
$ docker commit dbslab dbslab-before-commit
```

다시 psql 세션으로 돌아와서 4th-article을 쓰고 트랜잭션을 마칩니다.

```sql
-- continue psql sesison

INSERT INTO article (id, title, created_at) VALUES (
  4, concat('4th article - txid = ', txid_current()), now()
);

COMMIT;
```

이제 psql 세션은 닫아도 됩니다.

pg 서버 컨테이너에 접속해서 WAL이 잘 기록됐는지 확인해봅니다. WAL은 `/var/lib/pg-wal/` 디렉토리에 있습니다. [pg-waldump][pg-waldump] 명령과 앞서 확인한 트랜잭션 ID를 사용해서 WAL 기록을 확인합니다. (아래 `--xid=739` 부분을 자신이 확인한 트랜잭션 ID로 바꿔주세요.)

```console
$ docker exec -it dbslab /bin/ash

$ cd /var/lib/pg-wal/

$ pg_waldump 000000010000000000000001 --xid=739
rmgr: Heap        len (rec/tot):     54/   258, tx:        739, lsn: 0/01560D08, prev 0/01560CD0, desc: INSERT off 3 flags 0x00, blkref #0: rel 1663/5/16384 blk 0 FPW
rmgr: Btree       len (rec/tot):     53/   153, tx:        739, lsn: 0/01560E10, prev 0/01560D08, desc: INSERT_LEAF off 3, blkref #0: rel 1663/5/16387 blk 1 FPW
rmgr: Heap        len (rec/tot):     95/    95, tx:        739, lsn: 0/01560EE8, prev 0/01560EB0, desc: INSERT off 4 flags 0x00, blkref #0: rel 1663/5/16384 blk 0
rmgr: Btree       len (rec/tot):     64/    64, tx:        739, lsn: 0/01560F48, prev 0/01560EE8, desc: INSERT_LEAF off 4, blkref #0: rel 1663/5/16387 blk 1
rmgr: Transaction len (rec/tot):     34/    34, tx:        739, lsn: 0/01560F88, prev 0/01560F48, desc: COMMIT 2022-12-01 10:13:39.516558 UTC
pg_waldump: error: error in WAL record at 0/1561098: invalid record length at 0/15610D0: wanted 24, got 0
```

마지막에서 두 번째 줄에 `COMMIT`이 기록되어 있는 것을 확인합니다.

이제 커밋 후 시점(B)의 이미지를 만듭니다.

```console
$ docker commit dbslab dbslab-after-commit
```

이미지를 만들 때 사용한 컨테이너는 더이상 필요하지 않으니 지워도 됩니다.

```console
$ docker container stop dbslab
$ docker container rm dbslab
```

### Step 3) Failure 발생한 이미지 만들기

앞서 (A) 시점의 상태를 `dbslab-before-commit` 이미지로, (B) 시점의 상태를 `dbslab-after-commit` 이미지로 만들어두었습니다. `Dockerfile.crashed`를 확인해보면 `dbslab-before-commit`를 베이스로 하되, `dbslab-after-commit` 이미지에서 WAL 디렉토리만 복사해오도록 되어있습니다. 이러면 4th-article 삽입 및 커밋 작업의 로그는 쓰였지만 데이터는 output되지 않은 상황과 일치하게 됩니다.

`docker build` 명령을 사용해서 이미지를 빌드하고 `dbslab-crashed`라고 이름붙이겠습니다.

```console
$ docker build -f Dockerfile.crashed -t dbslab-crashed
```

## 문제

Failure가 발생한 컨테이너를 실행시켰을 때 어떤 복구 작업이 이루어질지 예상해보세요. 컨테이너를 실행시킨 후 서버 로그와 복구 이후 데이터를 확인해보고 예상 결과와 비교하세요.

## 해설

WAL에 트랜잭션 커밋까지 로그가 남아 있으므로 4th-article 쓰기 작업부터 트랜잭션 커밋에 까지 redo를 수행할 것을 예상할 수 있습니다.

다음 명령으로 서버를 실행시킵니다. 복구 작업이 수행됩니다.

```console
$ docker run -d --name dbslab-recovery dbslab-crashed
```

`docker logs` 명령어로 컨테이너 로그를 확인해봅니다. 비정상 종료로 복구를 시작한다는 내용과 redo를 수행한다는 내용의 로그를 확인할 수 있습니다.

```console
$ docker logs dbslab-recovery
```

```
(...생략)
2022-12-01 10:21:50.552 UTC [23] LOG:  database system was interrupted; last known up at 2022-12-01 10:09:17 UTC
2022-12-01 10:21:50.918 UTC [23] LOG:  database system was not properly shut down; automatic recovery in progress
2022-12-01 10:21:50.920 UTC [23] LOG:  redo starts at 0/1521C50
2022-12-01 10:21:50.923 UTC [23] LOG:  invalid record length at 0/15610D0: wanted 24, got 0
2022-12-01 10:21:50.923 UTC [23] LOG:  redo done at 0/1561098 system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
(...생략)
```

DB에 접속해서 `article` 테이블도 확인해봅니다.

```console
$ docker exec -it dbslab-recovery psql -U postgres
```

```sql
SELECT * FROM article;
```

```
 id |          title           |         created_at
----+--------------------------+----------------------------
  1 | hello                    | 2022-12-01 10:09:17.608912
  2 | initialized!             | 2022-12-01 10:09:17.609587
  3 | 3rd article - txid = 739 | 2022-12-01 10:11:49.136474
  4 | 4th article - txid = 739 | 2022-12-01 10:11:49.136474
(4 rows)
```

(WAL 디렉토리를 제외하고는) `dbslab-before-commit` 이미지를 사용했으므로 적어도 4th article은 쓰이지 않은 상황이었을텐데 WAL을 통해 복구가 이루어졌음을 확인할 수 있습니다.

[wal-intro]: https://www.postgresql.org/docs/15/wal-intro.html
[pg-waldump]: https://www.postgresql.org/docs/15/pgwaldump.html
