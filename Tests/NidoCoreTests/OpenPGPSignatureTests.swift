// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// The real `SHA256SUMS` and `SHA256SUMS.gpg` of Ubuntu 26.04 (resolute), fetched on 2026-11-09
/// and checked with `gpg --verify` against the same key.
@Suite(.italian) struct OpenPGPSignatureTests {
    static let sums = Data(base64Encoded: """
        MDE0MDg4ZTVhZWVhZjcyYTkwYThmNjdhZDkyYjc2NDYwMGY1ODNmN2NlMTI2ODU2M2M0Zjc5YzQ2NzRlODFiZiAqdWJ1bnR1\
        LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLnRhci5negowMmQ5MDhhY2QwZTM1OGNlODFkZTUyZTk4ZmUxOWU4NGZi\
        ZjZjNmEzMTY3ODI5NmVkZDU4MDA3NTMwZGY4OGY5ICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFtZDY0djMtcm9v\
        dC50YXIueHoKMDY1ODkzOTM4OTQ5YjhlZGNkMzhjNTJhMTY1MTFmYzI3YTI0MTVhMGQ3MmNmNTUxYmU5ODNlNGU2MjkxNTNm\
        NSAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hcm02NC1seGQudGFyLnh6CjA5Yjc3YTg3ZWZjMWQ0NTFmZjFlODY5\
        ZTQ1NjBhNDI2NzE2NWU0OTI5NzM1YmQ1MTZkZTQ1NTE3ODI3Y2RiNmMgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWct\
        YW1kNjR2My52bWRrCjA5ZWFjMTY1NGZmNGViZjAwYWY5NGY4YjQyYzRlNzdjN2E4MzQwYWFkYzFiNTcwMGU2MDQ4ZTljOTYy\
        NjdjMTMgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC5kYWlseS4yMDI2MDkyNy4yMDI2MTAxNi5pbWFn\
        ZV9jaGFuZ2Vsb2cuanNvbgowYTQzZmQ1ZTRjY2RjYzAwMjIzODRiYTY1MDE3ZTUwOTkyNzFjMDBjYTQ1OTkyYzFkZmQzZTQx\
        ZWQ1YWE4ZmIwICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFybWhmLnJlbGVhc2UuMjAyNjA5MjcuMjAyNjEwMTYu\
        aW1hZ2VfY2hhbmdlbG9nLmpzb24KMTM2NmUwYjA2NGNiMjBjNjJjNmRmMmE2ZmE4ODk1Yjk1NmU1ZmMyMTQ1M2U4MzNjNjYw\
        NjQ4NjFmYzZhMGY3YyAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hbWQ2NC1yb290Lm1hbmlmZXN0CjEzNjZlMGIw\
        NjRjYjIwYzYyYzZkZjJhNmZhODg5NWI5NTZlNWZjMjE0NTNlODMzYzY2MDY0ODYxZmM2YTBmN2MgKnVidW50dS0yNi4wNC1z\
        ZXJ2ZXItY2xvdWRpbWctYW1kNjQuc3F1YXNoZnMubWFuaWZlc3QKMTM2NmUwYjA2NGNiMjBjNjJjNmRmMmE2ZmE4ODk1Yjk1\
        NmU1ZmMyMTQ1M2U4MzNjNjYwNjQ4NjFmYzZhMGY3YyAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLXJv\
        b3QubWFuaWZlc3QKMTM2NmUwYjA2NGNiMjBjNjJjNmRmMmE2ZmE4ODk1Yjk1NmU1ZmMyMTQ1M2U4MzNjNjYwNjQ4NjFmYzZh\
        MGY3YyAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLnNxdWFzaGZzLm1hbmlmZXN0CjE1ZDY5N2ViZGIx\
        NmNjOWRiZTY4M2ZjODUzZmJlN2QyMzA3Yzg5ZWFlMzU2OGFiNWZmNDI2ZDI4NjY4YjAxOGIgKnVidW50dS0yNi4wNC1zZXJ2\
        ZXItY2xvdWRpbWctcmlzY3Y2NC50YXIuZ3oKMThiOTIzNjhhYjZjZDMzYTE3N2JhZGFiNTA1YjJmNDg5YjliZmJjZjg2ODY2\
        YjIyYzZkMWFmZDEzZmE2YWEzYiAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1zMzkweC5pbWcKMWRhNDU5YWUyYTU5\
        ZTc2ZTlkZTQ2MGQ0YjA3YzIzN2UxMWQxNWM3YmQ3MmFiNDRjODhhNmJjYzM1ZjA1NGIyZCAqdWJ1bnR1LTI2LjA0LXNlcnZl\
        ci1jbG91ZGltZy1hbWQ2NHYzLmltZwoxZTQyNjYyMjQ3NDFjMzVkMzRmMzRkZjczYWI2YjUxMGI4NmNmZDZmOTllYzM5ZDdk\
        YmVkZjNmODM0MDg5MGY0ICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLXBwYzY0ZWwudGFyLmd6CjI2NGUwMWQzMGU0\
        NzFiMjI4OGJmOTk1NjkyMTU1Nzk2YTQzMzk1YjRkYTg5YTQyYjM1MzY1MWJlN2JjYzQwZGMgKnVidW50dS0yNi4wNC1zZXJ2\
        ZXItY2xvdWRpbWctcHBjNjRlbC1seGQudGFyLnh6CjMxMDUyNmJlZDMwZDE3ZjM5ODBmNjUzMzVmNTJkZjE0Y2QyNjMzYTM0\
        NmJjZWMyYWVlZDczZmRkNTExNjVjM2YgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYXJtaGYudGFyLmd6CjNmNDY4\
        MjdhZWY5Y2YxYjUzZjMwYmExNWJkMDk1NmRmNjQ3NDFhNTNiNGU1ODNmMWM1YjU3MjY3NzdmODI4NzkgKnVidW50dS0yNi4w\
        NC1zZXJ2ZXItY2xvdWRpbWctczM5MHguZGFpbHkuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KNDJj\
        NjlhMDcwMDMzZmNmMGJiMmRjNWY5YmU0ZThhYmEwMGMzY2RlZmE3OWUzYmNjOWZlYTBkM2VlNTA1MWNmMSAqdWJ1bnR1LTI2\
        LjA0LXNlcnZlci1jbG91ZGltZy1zMzkweC5yZWxlYXNlLjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5qc29u\
        CjQ2YTdjOGY3ZDc3MGQ3ZWY2NzYwMjQwM2Q1NTdmN2ZkYTJkNTRjZDIwM2YxMTA3NjkyMDk3OGNhNjQ0NmVkYmMgKnVidW50\
        dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYW1kNjR2My5zcXVhc2hmcwo0ODI3OTFjMjQ4MGIzOTZjYThmODc5YjRiYmEwZjQ5\
        YTE0MTQwODZmMWE1ZDMxOGNjZGY0ZTMzZDdkMzY0MTM0ICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFybTY0LXJv\
        b3QudGFyLnh6CjRiNDAyZjliN2I1M2ZlZGRlOWIyMTQ1YTgxODJmYmQ3MzhjNmIzNjFmNTg4OTdkZTVjOTAxMjliODc2ODY2\
        NWYgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC1seGQudGFyLnh6CjUzMDlhMWNmMWU2MWMwNWE0MjIy\
        YjYzODFmMGJiNmMzOGZjMzJjYzk5NDFiZGI3MGUxOGQyZGY4NjVlZTYwYTEgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRp\
        bWctcmlzY3Y2NC5pbWcKNTY0NWQwMzE4YWQyMWY2NDNlYmIxYWM0NTY3NTE0NjIwZTk4OTMzODBiMDdiMDIwMWZkYTE2M2Jh\
        YTViN2ViNSAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hbWQ2NC5pbWcKNWVmMDBhMTkzMWU0NWM5YWY3MzRmNDJi\
        ZDUwYTc0MDU2OGZkNTk2NDZmNzM5ZDQyMjIyNGQyYjZlYjg2NmE5NyAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1h\
        cm1oZi5tYW5pZmVzdAo1ZmFmN2QzMWIzZTQzNDU4ZjQ3NTZkMWUwMjVhODU3MjQ4ODYxN2IzZmIzZThlYjM4YmYxYTJlY2M3\
        YzQwYzk5ICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLXBwYzY0ZWwubWFuaWZlc3QKNWZkZmE2ZWJhYWM1NzdlZWJj\
        MzZiYzdmYWEyOWJjNmVmOGI5MTVlYjM1ZTk1ZmEzNDA4ZjI1N2RhZTcxOGEwNSAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91\
        ZGltZy1wcGM2NGVsLXJvb3QubWFuaWZlc3QKNWZkZmE2ZWJhYWM1NzdlZWJjMzZiYzdmYWEyOWJjNmVmOGI5MTVlYjM1ZTk1\
        ZmEzNDA4ZjI1N2RhZTcxOGEwNSAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1wcGM2NGVsLnNxdWFzaGZzLm1hbmlm\
        ZXN0CjYwODYyZWNmYjJhM2MxODk4ZTIwYzZiOGQwMjkwYTBjMDcxODU0ZTc4MzY1ZTNiMjc1NGY2YzA3YWU2ZmM0NDMgKnVi\
        dW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC5zcXVhc2hmcwo2ODA2ZDc4N2ZjZTlmMWMzNWY3YWE2OWU3MDcz\
        MjBlMTc5MjA1MDE0OGZlYjZlZjU5Yjk4Zjk2OTg1MjcxZWQ4ICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLXMzOTB4\
        LnRhci5nego2ZGE1N2U4NGI5ZWRkNmJkNmE2NmZjNmQzMTE5ZWJiNzAyZGQyMTc0YmEzMzNkM2I2Y2M4ZmVmOGIxMTg3YWNl\
        ICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFybWhmLXJvb3QubWFuaWZlc3QKNmRhNTdlODRiOWVkZDZiZDZhNjZm\
        YzZkMzExOWViYjcwMmRkMjE3NGJhMzMzZDNiNmNjOGZlZjhiMTE4N2FjZSAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGlt\
        Zy1hcm1oZi5zcXVhc2hmcy5tYW5pZmVzdAo3MGZhNjk1MThjMDY5NzVlMGMwNTJhOTBmZDFiMjBmMTQ1OGRiZWU0MDdiNzJh\
        MzcwYzYzZDFhMDE5ZDhjODI1ICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLXJpc2N2NjQubWFuaWZlc3QKNzE5NTEw\
        MDZlMTJkM2U3ZDU0MTY5MWM2Njg5ZjRkMDllODIwMTlmYTdkOGYzZjYzZTAzZDQ4Nzk2MDBhOTM2YiAqdWJ1bnR1LTI2LjA0\
        LXNlcnZlci1jbG91ZGltZy1zMzkweC1yb290LnRhci54ego3MmE4YTQxMGUyN2YwYzkwNTYwMTBmZWFiMDRlZDg4ZjJkN2Iz\
        ODdjYmZlMzgxYzFmZDRiOWY5MzM3ZDc3MjFkICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLXMzOTB4LWx4ZC50YXIu\
        eHoKNzJjNmExOGQ5OWMyZmRmNjVlNGJiYTI3Mzk4OTFlZjk5ZDQ1NjhkY2RiMjIzM2JmYzc2MjQ3MGY0MTFjOTVlMSAqdWJ1\
        bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hcm02NC50YXIuZ3oKNzRlYjJhNzJmODFlZjYzNTA3MGQ1NDU3MDlkYTdiMjRm\
        YjMxYWUyN2YyNGI4YzZiNGJjNGRhNDQ3ZjczNjEwNCAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hcm1oZi5zcXVh\
        c2hmcwo3Njk0YjExY2I3N2RjMWI3YjBmNDI4NWQ2OGRjMTc2YThjYTk4ZGY2MWYwMzg5OWU4MTcwZDE4NTA5Y2ExMjRmICp1\
        YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLXBwYzY0ZWwuaW1nCjgwZThjMzBlODA0YjlhMDQzZDQ1NGEzMWYxNTM0NmU2\
        MjMzMzVmMzYyMzNmYTEyYzBkNjIzYzI5Y2EyNTU5YjYgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC5k\
        YWlseS4yMDI2MDkyNy4yMDI2MTAxNi5pbWFnZV9jaGFuZ2Vsb2cuanNvbgo4MmMxMjc1NTYxM2U2NDY4OTI2ZTA5ZTQyYjdk\
        Y2YyMjk0NTQzZDE2NmNiODA4YWIzY2Q3Mjk3Y2JiNzU4ZWVkICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFybWhm\
        LWx4ZC50YXIueHoKODMwZTY4YjA4OTJkMTRlNWU4ODYwNDhhMjM3OWEyODdmNjUyYzg4ZWUzNDQwZTRhYWIwODIwZjA1Y2Vj\
        OGJkMiAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hcm02NC5tYW5pZmVzdAo4OTllZWVhYmM3OGU4MzA2MjI1NmZj\
        YzEwNjZmZGY5NjlmZTk0ZTRjODI4ZTk5MTZjOTVjZDY4Mjc3NTczNTE1ICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1n\
        LWFtZDY0LnNxdWFzaGZzCjhiYTg2ZjFkNDM2YzE2YTM0NzllOWQ2NDgwYjBmMGYwZWJhZmFjMDMyM2FjNjhiMzcwNDIwYmQ1\
        NmM4ZDkzZjggKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYW1kNjR2My1seGQudGFyLnh6CjhlNWMzYjZjNjFlYWQz\
        N2JlNzJhMmNjMjRkMzRhOGFmN2MzYWVlNTUyNzdmNWYyZTk4NmYwZmVhYTg4MDI5MTMgKnVidW50dS0yNi4wNC1zZXJ2ZXIt\
        Y2xvdWRpbWctYW1kNjQudGFyLmd6CjhlYjg3NmMyY2NjNGI2ZmY4OWU0YTY1ZDUxMTgxNTkyM2IyODVlMDQ1MDNiYTQ2NTgw\
        OWJmNTg3Zjc2M2RhMjQgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYXJtNjQuaW1nCjk0YTMzODMyZGM0ZjBjNzc3\
        NWVlY2U4NzA5ZWU4ODYxZWE5OTMzOTdhNTBhYTE1OTFhNTlhNjkxOWE5NzVkNTMgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xv\
        dWRpbWctYW1kNjQuZGFpbHkuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KOTRhMzM4MzJkYzRmMGM3\
        Nzc1ZWVjZTg3MDllZTg4NjFlYTk5MzM5N2E1MGFhMTU5MWE1OWE2OTE5YTk3NWQ1MyAqdWJ1bnR1LTI2LjA0LXNlcnZlci1j\
        bG91ZGltZy1hbWQ2NHYzLmRhaWx5LjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5qc29uCjlmNDc2M2MxZmI0\
        ZjU0MTkzYThlZWMxMzM4NGFkMzg4YjRiZDQxODkyZDFlNGExYzUzM2RjOTM0YmU3YzJhMTggKnVidW50dS0yNi4wNC1zZXJ2\
        ZXItY2xvdWRpbWctYXJtaGYuaW1nCmEzN2QyZTdjMjU4OWNjN2I2YTc3ZjFjNDJiYjdhODUwODE0ZjNmNTk2YmU0NmM0ZTNj\
        YjhlMmRkMmUxNzIwY2IgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctczM5MHgtcm9vdC5tYW5pZmVzdAphMzdkMmU3\
        YzI1ODljYzdiNmE3N2YxYzQyYmI3YTg1MDgxNGYzZjU5NmJlNDZjNGUzY2I4ZTJkZDJlMTcyMGNiICp1YnVudHUtMjYuMDQt\
        c2VydmVyLWNsb3VkaW1nLXMzOTB4LnNxdWFzaGZzLm1hbmlmZXN0CmE1MzVkMTAyYmI5YTRkMjVjMWY2MTQwZTVkNDM2Y2Ux\
        NmFlOGFjYWFlYjU3ZDE1YjNiZGIzYjVmYTQ1ODNmMWEgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYXJtNjQuZGFp\
        bHkuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KYWE5NGFkNTNiMDZkNjIwNmJhOTNkYTY2ZGY4Mzg2\
        MWJjMWY3NzllYjkxZGViMDcyMzk1NWQyMTdiNTgwZTU4ZiAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hcm02NC1y\
        b290Lm1hbmlmZXN0CmFhOTRhZDUzYjA2ZDYyMDZiYTkzZGE2NmRmODM4NjFiYzFmNzc5ZWI5MWRlYjA3MjM5NTVkMjE3YjU4\
        MGU1OGYgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYXJtNjQuc3F1YXNoZnMubWFuaWZlc3QKYWQwZmUwNTI2YmYz\
        NDNjNTY1MTJhZDdmYjJkZjE0MzJhZjlmOGViYzhiMDZkNTg3YTVlMGU0YTQzZWQyY2JhZiAqdWJ1bnR1LTI2LjA0LXNlcnZl\
        ci1jbG91ZGltZy1hbWQ2NHYzLm92YQphZDFlMzdiOWU3YTY0OTFlNWY1OWIzYzU4ZmU2ZWM2ZDExNzBlZWI2NWJhZjE1ZjY4\
        MDI3ODlhYWI5M2Q2MjMwICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFybTY0LnJlbGVhc2UuMjAyNjA5MjcuMjAy\
        NjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KYjU3NTI1NTczMzg2ZGVjZDVmY2QzODFiOTVkZGJiYzFmMDI2Y2IwOWE3MjRi\
        ZDUwZDE5ZGRjNmVjNGNlYzc1MCAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1yaXNjdjY0LXJvb3QudGFyLnh6CmI1\
        N2MyOWJhMzM4ZjExZGY4OTcyNWQxNTlmZDFjYjkzMjFhZmIxZGU5MDE3NDA2ODYxZTcxMTE4NDliZDBkMmEgKnVidW50dS0y\
        Ni4wNC1zZXJ2ZXItY2xvdWRpbWctczM5MHgubWFuaWZlc3QKYmE2Zjg0YWEzZThlNGZiNDgzZDQ3ODhmMzY2NWQxMTViMmFh\
        MTgyZWNlMjg3YTIwMjI3OWM3YTc3N2Q2N2QzZSAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hcm02NC5zcXVhc2hm\
        cwpjOWE1YmUzMmRlMDhlYTg0MjliZTdjYTcxOTI0MzcyYjA1NmZmN2FiMjI4MjRjYjI4NTdjNGE5YTZhNjkwNGY4ICp1YnVu\
        dHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFtZDY0LXJvb3QudGFyLnh6CmQ1MmFkYjRhZTVhNzMxZGNiZWQ1ZWJlNjY0NzU3\
        ZDI0OGY2YzA5OTRkYzYyMzBjODg4OTFmMTc2M2E4MTgwODMgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYW1kNjQu\
        bWFuaWZlc3QKZDUyYWRiNGFlNWE3MzFkY2JlZDVlYmU2NjQ3NTdkMjQ4ZjZjMDk5NGRjNjIzMGM4ODg5MWYxNzYzYTgxODA4\
        MyAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLm1hbmlmZXN0CmQ2MWI5NjZkNTIyMjY1NzgxYmVjOGI0\
        OWJmNjViZTcyZWEyMWQwZGQ1YTdkNzYyMGNhMzdiOWE5N2VmZDUzMjIgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWct\
        czM5MHguc3F1YXNoZnMKZGMyYmUyNjczYmUzN2FmMjA2NmE3MTcxYzU5ZGVjYTJhOWZiNGQ3ODI0N2I3YTk4MmIxYTBiZDky\
        NTEyMzVmOSAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1wcGM2NGVsLnJlbGVhc2UuMjAyNjA5MjcuMjAyNjEwMTYu\
        aW1hZ2VfY2hhbmdlbG9nLmpzb24KZGU1MThiMzI0ZjMyNjhkOTVjNzEyN2YwYTdjZWNjYmE5OWUzYTUxZGZiZmZmNmY0NzU5\
        NDU0ZDU5ZGZmOGNiNSAqdWJ1bnR1LTI2LjA0LXNlcnZlci1jbG91ZGltZy1wcGM2NGVsLXJvb3QudGFyLnh6CmRlN2E2NWY2\
        MmZiNWM2MTg3NjdiOGUwYmRmYjUxNTBjYmRmZGY1MGI3NDEwM2E0NTM1Njk5MTY3YjU1MjMyMzYgKnVidW50dS0yNi4wNC1z\
        ZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC5zcXVhc2hmcwplNTkxMDY3NTlmYmRmMWNiYzk3YWEzZDM1MTQ5M2I4ZGU0NjI4MzY0\
        ZGNhZWE0ZTkyMDFmNDQ2MmU1MzY2NWQyICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFtZDY0LWx4ZC50YXIueHoK\
        ZWJkODRjNzIxYWViYmM4MDQ4NTBmZTE1YTNlMGExZmEwOTljODBkZWNkMGY5ZTIzYTI4YTBjYjQwMjUzZTVhOSAqdWJ1bnR1\
        LTI2LjA0LXNlcnZlci1jbG91ZGltZy1hbWQ2NC5yZWxlYXNlLjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5q\
        c29uCmViZDg0YzcyMWFlYmJjODA0ODUwZmUxNWEzZTBhMWZhMDk5YzgwZGVjZDBmOWUyM2EyOGEwY2I0MDI1M2U1YTkgKnVi\
        dW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYW1kNjR2My5yZWxlYXNlLjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5n\
        ZWxvZy5qc29uCmVjOTI2NzIzYjA1ZGE0NDU4NDk3YjhiMmJhMjBmZDE3YTZjNDcxOWNkZmRhZmJjYzZiZjEwNzkxYzAyY2Jk\
        OWMgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC1yb290Lm1hbmlmZXN0CmVjOTI2NzIzYjA1ZGE0NDU4\
        NDk3YjhiMmJhMjBmZDE3YTZjNDcxOWNkZmRhZmJjYzZiZjEwNzkxYzAyY2JkOWMgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xv\
        dWRpbWctcmlzY3Y2NC5zcXVhc2hmcy5tYW5pZmVzdApmMTEzMTY3YmU1YjZhYTBkMGQ1OTU1MGU2OTYwOWY2MDkzYmExNTAz\
        YWRhNGQzMjMyZjI0MDUwZDU5MDIxNzcxICp1YnVudHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFybWhmLmRhaWx5LjIwMjYw\
        OTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5qc29uCmYyMTE1YmQ5ZmNjMjUzNjliNzBmNzMzNWY4ZGY5N2E5ODFhZjZm\
        MmE0Njk5Y2FkMGI2M2M2ODQ2Zjg5ODUxOTggKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC5yZWxlYXNl\
        LjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5qc29uCmY0YTk4YmRmMzdlYjk5MzhmZDJhNzBjN2ZhZDExZmMw\
        NjdkMDUwN2I1MGQxZTdlNmMyZDU5NWIyYjczZGRlNmQgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYW1kNjQudm1k\
        awpmNzg4Y2FkYmYzZDRlYzY2NGRhNDU1ZjFmNGU3OTRjYjE1YTRmZDc0MTEyMDBiMWEyMjM0YjRjYjJkMzRlMDE2ICp1YnVu\
        dHUtMjYuMDQtc2VydmVyLWNsb3VkaW1nLWFybWhmLXJvb3QudGFyLnh6CmZiNTJlZWI3OWMwZTcxYmNlNjc1NzI5YTdkNjdm\
        NWEwYzY2OTFkZWVhMDRkMmIxM2E1MjRjN2UzNzZkNzRlYzEgKnVidW50dS0yNi4wNC1zZXJ2ZXItY2xvdWRpbWctYW1kNjQu\
        b3ZhCg==
        """)!

    static let signature = Data(base64Encoded: """
        LS0tLS1CRUdJTiBQR1AgU0lHTkFUVVJFLS0tLS0KCmlRSXpCQUFCQ2dBZEZpRUUwdXRFWW0vZHd3dFJQVnUzR2wxc1RIMjRm\
        SUVGQW1yWG1vWUFDZ2tRR2wxc1RIMjQKZklFY0ZRLy9aTC83Tjc3SmRqRGowdEQyMUdSTXBQYjE4MmExWXpBaWJCTzkrak9B\
        eXoxSmcwR0xzaDVJT1NuUwpsMGFYdWxhZDNza3Arc0RSMGVCMERZcGZGeFZHeXJFZlphVEIrRURwaEtvYldXVXJYbE0zTVox\
        ZnlrMUNobVQyCnJXVE1EamkvK0ZsbWVxSmQzb2ZudVdTOVU2UGRNUWVxUDU4WTEyaWx1aDlTUnVqT05ZOTE3eWpaa01RYTVi\
        UVEKcUF1MWpoMTBoNHlpWWU3Y3BsRVVVZG5MSGoveExkY1hXTjV3OFV2Lys2dUlubUp6QnlLUFRSOXBHY1FlWUpVSAorNHdo\
        ZUw5aUowVkJRQzN5UHFxZXA2SlF3WFVFZW40dTIvRlNyQ2FDNS9kNUFmdWhtck9qbFlyNFE4RWY1RVQ5CkltV0Q0OXM4RlFU\
        cy94NEFvUkJDcURlWVBBVTNjRHArYkdpUmNhbmRVS0ZlZi9hRHEycFVKK3RNaG5nVXZqMmwKSHdTRjlYWDUrc0lVYlFyUENM\
        LzB1VVN1VmM0Wks5TmQ1blVIVGtCenFicDduMWZqMlpwd0RuVVFQWnRPb3h0Mgo1OUM5YWU5Rk1wTGEyYUdKaHNvbVQ5RWdM\
        U3I2U1d3b1IrcUFBNEliVVpNL3hNdi9Rckc3TkNOVUtIRWN0WjRmClRjM2VvYy92TEwzRXpHTDZ5OTNJY0hxUHI4eDlDRVdH\
        L1hDNjVsdUs4dVBKVlc0N1pURjZFL0g5Z1ltTXkyQVUKZEZwUUJUVVlxV21vdExPeUx2V2hEZVIzSnpoaENNemNCRjBFc3hW\
        WGVZMXAxR2dhZEtaMW1WRFNIZG5CcFBkWQord2FLRnZLR0xLY1V3cGxQSlAzNDlWSkpwZXlrbGpSMXkvS05wZlcvU05YNld2\
        Z2lIK289Cj14Y2FJCi0tLS0tRU5EIFBHUCBTSUdOQVRVUkUtLS0tLQo=
        """)!

    @Test func embeddedKeyHasTheExpectedFingerprint() {
        #expect(UbuntuCloudImageKey.key.fingerprint == "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81")
        #expect(UbuntuCloudImageKey.key.modulus.count == 512)  // RSA 4096
    }

    @Test func ubuntuSignatureVerifies() throws {
        let created = try OpenPGPSignature.verify(Self.signature, of: Self.sums, key: UbuntuCloudImageKey.key)
        // The creation time of the fixture's signature (26.04 list, autumn 2026).
        #expect(created > Date(timeIntervalSince1970: 1_767_225_600))  // 2026-01-01
        #expect(created < Date(timeIntervalSince1970: 1_798_761_600))  // 2027-01-01
    }

    @Test func tamperedListIsRefused() {
        var tampered = Self.sums
        tampered[100] ^= 0x01
        #expect(throws: NidoError.downloadFailed("firma della lista dei checksum non valida")) {
            try OpenPGPSignature.verify(Self.signature, of: tampered, key: UbuntuCloudImageKey.key)
        }
    }

    @Test func tamperedSignatureIsRefused() {
        var binary = try! OpenPGP.dearmor(Self.signature)
        binary[binary.count - 5] ^= 0x01  // inside the RSA value
        let signature = Data(binary)
        // The binary form verifies as well as the armored one.
        #expect((try? OpenPGPSignature.verify(Data(try! OpenPGP.dearmor(Self.signature)), of: Self.sums,
                                              key: UbuntuCloudImageKey.key)) != nil)
        #expect(throws: NidoError.downloadFailed("firma della lista dei checksum non valida")) {
            try OpenPGPSignature.verify(signature, of: Self.sums, key: UbuntuCloudImageKey.key)
        }
    }

    @Test func otherKeyIsRefused() throws {
        // Same layout, another modulus: the issuer fingerprint and RSA both fail.
        var body = [UInt8](Data(base64Encoded: UbuntuCloudImageKey.packetBody)!)
        body[20] ^= 0x01
        let other = try OpenPGPPublicKey(packetBody: body)
        #expect(other.fingerprint != UbuntuCloudImageKey.fingerprint)
        // The signature names its issuer: a new key of the signer, not a broken list.
        do {
            try OpenPGPSignature.verify(Self.signature, of: Self.sums, key: other)
            Issue.record("another key must be refused")
        } catch NidoError.downloadFailed(let reason) {
            #expect(reason.hasPrefix("lista dei checksum firmata con una chiave che Nido non conosce ("))
            #expect(reason.contains("1A5D6C4C7DB87C81)"))
            #expect(reason.hasSuffix("serve una versione di Nido aggiornata"))
        }
        let issuer = try #require(OpenPGP.issuer(of: try OpenPGP.packet(try OpenPGP.dearmor(Self.signature), at: 0).body))
        #expect(UbuntuCloudImageKey.fingerprint.hasSuffix(issuer))
    }

    /// A key change announced by the signer: both keys built in, the list verifies with
    /// whichever signed it, in any order; with neither, the issuer is named.
    @Test func eitherOfTwoKeysVerifies() throws {
        var body = [UInt8](Data(base64Encoded: UbuntuCloudImageKey.packetBody)!)
        body[20] ^= 0x01
        let next = try OpenPGPPublicKey(packetBody: body)
        let created = try OpenPGPSignature.verify(Self.signature, of: Self.sums, key: UbuntuCloudImageKey.key)
        #expect(try OpenPGPSignature.verify(Self.signature, of: Self.sums, keys: [next, UbuntuCloudImageKey.key]) == created)
        #expect(try OpenPGPSignature.verify(Self.signature, of: Self.sums, keys: [UbuntuCloudImageKey.key, next]) == created)
        var tampered = Self.sums
        tampered[100] ^= 0x01
        #expect(throws: NidoError.downloadFailed("firma della lista dei checksum non valida")) {
            try OpenPGPSignature.verify(Self.signature, of: tampered, keys: [next, UbuntuCloudImageKey.key])
        }
        do {
            try OpenPGPSignature.verify(Self.signature, of: Self.sums, keys: [next])
            Issue.record("a list by a key not built in must be refused")
        } catch NidoError.downloadFailed(let reason) {
            #expect(reason.contains("chiave che Nido non conosce (") && reason.contains("1A5D6C4C7DB87C81)"))
        }
        #expect(throws: NidoError.self) { try OpenPGPSignature.verify(Self.signature, of: Self.sums, keys: []) }
    }

    @Test func crlfArmorVerifies() throws {
        let crlf = Data(String(decoding: Self.signature, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8)
        try OpenPGPSignature.verify(crlf, of: Self.sums, key: UbuntuCloudImageKey.key)
        // A date before 1970 does not trap.
        try OpenPGPSignature.verify(Self.signature, of: Self.sums, key: UbuntuCloudImageKey.key,
                                    now: Date(timeIntervalSince1970: -10))
        #expect(throws: NidoError.self) { _ = try OpenPGPPublicKey(packetBody: [4] + [UInt8](repeating: 0, count: 0x10000)) }
    }

    @Test func garbageIsRefused() {
        #expect(throws: NidoError.self) {
            try OpenPGPSignature.verify(Data("<html>404</html>".utf8), of: Self.sums, key: UbuntuCloudImageKey.key)
        }
        #expect(throws: NidoError.self) {
            try OpenPGPSignature.verify(Self.signature.prefix(40), of: Self.sums, key: UbuntuCloudImageKey.key)
        }
        #expect(throws: NidoError.downloadFailed("firma della lista dei checksum assente")) {
            try OpenPGPSignature.verify(Data(), of: Self.sums, key: UbuntuCloudImageKey.key)
        }
    }
}
