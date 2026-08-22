# 사업장 안전신문고 — 모바일 QR 신고 시스템

현장에서 QR을 스캔해 앱 설치 없이 위험요인을 신고하고, 담당 부서가 조치한 결과를
전 직원이 실시간으로 공유하는 시스템입니다.

기획안 「안전신문고 QR 화면 구성 및 단계별 프로세스 기획안」의 5단계 화면을 구현했습니다.

- **프런트**: GitHub Pages (정적 파일 3개, 빌드 과정 없음)
- **백엔드**: Supabase (PostgreSQL) — RPC 함수로만 접근
- **UI**: 기존 「현장 안전점검 실시간 보고」 시스템의 디자인 체계를 계승

---

## 1. 화면 구성

| 단계 | 화면 | 내용 |
|---|---|---|
| 1 | 메인 홈 | QR 접속 첫 화면. 대형 **[신고하기]** · 우상단 **[관리자]** · 하단 실시간 처리현황 |
| 2 | 신고 작성 | 소속·성명 · 구분 칩 3종(청사안전/시설환경/기타) · 상세내용 · 사진 최대 3장 · 알약형 [제출하기] |
| 3 | 처리 현황판 | 전 사업장 공유. 신고부서/구분/상세내역/처리결과/조치내역 · 필터·검색 · CSV/PDF |
| 4 | 관리자 인증 | 부서 선택 + PIN 6자리 (최초 접속 시 직접 설정) |
| 5 | 조치 입력 | 처리예정 → 처리중 → 처리완료 · 조치내역 작성 · 저장 즉시 현황판 반영 |
| ＋ | QR 생성 | 사업장·세부위치별 부착용 QR 스티커. PNG 저장 / 인쇄 |

사업장은 **본사 + 10개 본부** 기준입니다. `index.html`의 `SITES` 배열 한 곳만 고치면
신고폼·필터·PIN·QR 전체에 반영됩니다.

---

## 2. 설치 (최초 1회)

### ① Supabase 프로젝트 만들기

[supabase.com](https://supabase.com) → New project. 리전은 **Northeast Asia (Seoul)** 권장.

### ② 스키마 적용

대시보드 → **SQL Editor** → 새 쿼리 → [`supabase/schema.sql`](supabase/schema.sql) 전체를
붙여넣고 **Run**.

> 접근코드는 현재 **`admin`** 으로 설정되어 있습니다. 파일 안의
> ```sql
> insert into sr_config (id, access_code) values (1, 'admin')
> ```
> 이 자리가 사이트 접근코드이고, QR 주소에 `?k=<코드>`로 들어갑니다.
>
> **이미 한 번 실행한 뒤**에 코드를 바꿀 때는 위 INSERT를 고쳐도 소용없습니다(멱등이라
> 무시됨). 아래 UPDATE 한 줄을 실행하세요.

두 번 실행해도 안전합니다(멱등). 나중에 코드를 바꾸려면:

```sql
update sr_config set access_code = '새코드' where id = 1;
```

### ③ 연결 정보 입력

대시보드 → **Settings → API** 에서 두 값을 복사해 [`config.js`](config.js)에 넣고 커밋합니다.

```js
window.SR_CONFIG = {
  SUPABASE_URL:      "https://xxxxxxxxxxxx.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOi..."
};
```

- `anon public` 키만 사용합니다. **공개 저장소에 올라가도 되는 키입니다.**
- `service_role` 키는 절대 넣지 마세요.

### ④ GitHub Pages

Settings → Pages → Source: **Deploy from a branch** → `main` / `/ (root)`.

---

## 3. 보안 구조

정적 사이트라 서버가 없고 브라우저가 DB에 직접 붙습니다. anon 키는 공개되므로,
**키를 아는 것만으로는 아무것도 못 하도록** 설계했습니다.

```
브라우저 ──anon 키──> PostgREST ──> sr_* 함수 (SECURITY DEFINER)
                                        │
                          RLS 전면 차단된 테이블
```

| 방어선 | 내용 |
|---|---|
| **테이블 직접 접근** | 4개 테이블 모두 RLS 활성 + **정책 0개** → anon 키로 SELECT/INSERT 모두 불가 |
| **접근코드** | 모든 함수가 첫 인자로 코드를 검증. 틀리면 즉시 예외 |
| **PIN 저장** | bcrypt 해시(pgcrypto). 해시가 브라우저로 내려오는 경로 자체가 없음 |
| **세션** | 로그인 시 랜덤 48자 토큰 발급, 8시간 만료. 이후 요청은 토큰으로 |
| **수정 범위** | 부서 담당자는 **자기 사업장 건만** 수정 가능. 마스터만 전 사업장 |
| **폭주 방지** | 1분에 20건 초과 접수 차단 |

### 검증

스키마는 실제 PostgreSQL 18에 올려 **57개 테스트를 통과**했습니다
(권한 차단 · 해시 저장 · 타 사업장 수정 차단 · 세션 만료 · 접근코드 변경 즉시 반영 포함).
클라이언트는 같은 스키마를 얹은 로컬 서버에서 전 흐름을 통과시켰습니다.

### 남는 위험

- **사진 업로드**는 Storage 버킷에 직접 올라갑니다. anon 키를 가진 사람이
  3MB 이하 이미지를 올릴 수 있습니다(용량·확장자 제한은 걸려 있음).
  악용 정황이 보이면 대시보드에서 버킷 정책을 잠그면 됩니다.
- **접근코드는 QR 안에 들어 있습니다.** QR 사진이 외부로 나가면 코드도 나갑니다.
  그때는 `sr_config`의 코드를 바꾸고 QR을 다시 뽑으면 즉시 무효화됩니다.

---

## 4. PIN 운영

| 상황 | 동작 |
|---|---|
| 부서 최초 로그인 | 화면이 **"PIN 최초 설정"** 모드로 바뀜. 6자리를 두 번 입력해 등록 |
| 이후 로그인 | 등록한 PIN으로 인증 |
| PIN 변경 | 관리자 페이지 → **[PIN 변경]** (본인 부서만) |
| PIN 분실 | **마스터 관리자**가 초기화 → 해당 부서가 다음 로그인 때 새로 설정 |

**마스터 PIN도 같은 방식으로 최초 1회 설정**합니다. 관리자 인증 화면의 부서 목록
맨 아래 **[🔑 마스터 관리자]** 를 고르면 됩니다.

> 마스터 PIN은 부서 PIN을 초기화할 수 있는 유일한 수단입니다.
> 분실하면 Supabase 대시보드에서 직접 지워야 합니다:
> ```sql
> update sr_config set master_hash = null where id = 1;
> ```

`111111` 같은 반복 숫자와 `123456`은 설정 단계에서 거부됩니다.

---

## 5. QR 부착 운영

관리자 페이지 → **[QR 생성]** 에서 사업장과 세부 위치를 넣으면 스티커가 만들어집니다.

```
https://joongyu01.github.io/kpetrosafety/?site=jng&k=<접근코드>&loc=지하주차장%20B구역
```

스캔하면 **접근코드 입력 없이** 바로 신고 화면이 열리고, 사업장·세부위치가
자동으로 채워집니다. 신고 건에도 그 위치가 함께 기록됩니다.

사업장 코드: `hq · sn · sb · djs · cb · jng · jb · bun · dgb · gw · jj`

QR 코드는 외부 라이브러리 없이 직접 생성합니다. 표준 구현과 996개 케이스 모듈 단위 일치,
인코딩→렌더→디코딩 왕복 156/156을 확인했습니다.

---

## 6. 파일

```
kpetrosafety/
├── index.html            앱 전체 (단일 파일)
├── config.js             Supabase 연결 정보 ← 여기만 채우면 됨
├── supabase/schema.sql   DB 스키마 · RPC 함수 · 권한 · 스토리지
├── .nojekyll             GitHub Pages Jekyll 처리 비활성화
└── README.md
```

`index.html`은 로고와 QR 인코더까지 포함한 단일 파일입니다. 빌드 과정이 없어
GitHub 웹 편집기에서 직접 고쳐도 바로 반영됩니다.

---

## 7. 데이터 확인 / 백업

현황판에서 **CSV 내려받기**(엑셀에서 바로 열림) 또는 **PDF/인쇄**를 쓰면 됩니다.
전체 백업은 Supabase 대시보드 → Database → Backups.

```sql
-- 현재 설정 확인
select access_code, master_hash is not null as master_set from sr_config;

-- PIN 설정된 부서
select dept, set_at from sr_dept_pin order by dept;

-- 사업장별 처리 현황
select site, status, count(*) from sr_report group by site, status order by site;
```

---

## 8. 운영 전 정해야 할 것

| 항목 | 현재 | 검토 필요 |
|---|---|---|
| 익명 신고 | 불가 (소속·성명 필수) | 안전신고 특성상 익명 허용 여부 |
| 신고자 공개 | 현황판에 부서만, 관리자 화면에 이름 | 이름 공개 범위 |
| 처리 기한 | 없음 | 상태별 기한 및 지연 알림 |
| 세션 유지 | 8시간 | 사업장 공용 PC 사용 시 더 짧게 |
| 사내망 접근 | — | 현장 단말에서 `*.supabase.co` 방화벽 확인 |

---

© 2026 Korea Petroleum Quality &amp; Distribution Authority.
Developed by Joongyu Shin.
