import gzip
import importlib.util
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, 'src', 'router-files', 'usr', 'bin', 'iptv-auth.py')


def load_module():
    spec = importlib.util.spec_from_file_location('iptv_auth_under_test', SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ParserTest(unittest.TestCase):
    def setUp(self):
        self.m = load_module()
        self.m.log = lambda *args, **kwargs: None

    def test_missing_fcc_fields_do_not_truncate_later_channels(self):
        text = (
            'addChannel(\'ChannelName="A台",ChannelURL="igmp://1|rtsp://x",'
            'ChannelSDP="rtsp://1.2.3.4:554/live/a.sdp",'
            'ChannelFCCIP="1.1.1.1",ChannelFCCPort="15970"\');\n'
            'addChannel(\'ChannelName="B台",ChannelURL="igmp://2|rtsp://x",'
            'ChannelSDP="rtsp://1.2.3.4:554/live/b.sdp"\');\n'
            'addChannel(\'ChannelName="C台",ChannelURL="igmp://3|rtsp://x",'
            'ChannelSDP="rtsp://1.2.3.4:554/live/c.sdp",'
            'ChannelFCCIP="1.1.1.1",ChannelFCCPort="15970"\');\n'
        )
        rows = self.m._parse_channel_rows(text)
        self.assertEqual([r[0] for r in rows], ['A台', 'B台', 'C台'])
        self.assertEqual(rows[1][3:], ('', ''))
        self.assertEqual(rows[2][1:3], ('igmp://3|rtsp://x', 'rtsp://1.2.3.4:554/live/c.sdp'))

    def test_catchup_channel_id(self):
        self.assertEqual(
            self.m._catchup_channel_id('rtsp://1.2.3.4:554/live/ch123.sdp?x=1'), 'ch123')
        self.assertEqual(self.m._catchup_channel_id('rtsp://1.2.3.4:554/other/x.mpg'), '')

    def test_fetch_channels_keeps_code_alignment_with_missing_fields(self):
        text = (
            'addChannel(\'ChannelName="A台",ChannelURL="igmp://1|rtsp://x",'
            'ChannelSDP="rtsp://1.2.3.4:554/live/a.sdp"\');\n'
            "jsSetChannelInfo('1','2','3','4','codeA');\n"
            'addChannel(\'ChannelName="B台",ChannelURL="igmp://2|rtsp://x",'
            'ChannelSDP="rtsp://1.2.3.4:554/live/b.sdp"\');\n'
            "jsSetChannelInfo('1','2','3','4','codeB');\n"
        )

        class Resp:
            pass

        class Session:
            def post(self, *args, **kwargs):
                resp = Resp()
                resp.text = text
                return resp

        self.m.config = {'IPTVServer': 'http://x', 'filter_pip': False,
                         'filter_keywords': []}
        self.m.rtsp_source_ip = ''
        self.m.write_replayd_state = lambda: None
        channels = self.m.fetch_channels(Session())
        self.assertEqual([(c[1], c[2]) for c in channels],
                         [('codeA', 'A台'), ('codeB', 'B台')])


class OutputTest(unittest.TestCase):
    def setUp(self):
        self.m = load_module()
        self.m.log = lambda *args, **kwargs: None
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.m.EPG_PATH = os.path.join(self.tmp.name, 'PL.xml')
        self.m.EPG_GZ_PATH = self.m.EPG_PATH + '.gz'

    def test_epg_plain_and_gzip_match(self):
        data = [(1, 'CCTV1高清', [[('20261017090000 +0800', '新闻 <直播> & 测试',
                                   '20261017100000 +0800')]])]
        self.m.generate_epg_xml(data)
        with open(self.m.EPG_PATH, encoding='utf-8') as f:
            plain = f.read()
        with gzip.open(self.m.EPG_GZ_PATH, 'rt', encoding='utf-8') as f:
            packed = f.read()
        self.assertEqual(plain, packed)
        self.assertIn('新闻 &lt;直播&gt; &amp; 测试', plain)

    def test_fcc_suffix_requires_both_fields(self):
        self.assertEqual(self.m._fcc_suffix('1.1.1.1', '15970'), '/?fcc=1.1.1.1:15970')
        self.assertEqual(self.m._fcc_suffix('1.1.1.1', ''), '')
        self.assertEqual(self.m._fcc_suffix('', '15970'), '')
        self.assertEqual(self.m._fcc_suffix(None, None), '')


class RobustnessTest(unittest.TestCase):
    def setUp(self):
        self.m = load_module()

    def test_cfg_int_falls_back(self):
        self.assertEqual(self.m._cfg_int('12', 4), 12)
        self.assertEqual(self.m._cfg_int('abc', 4), 4)
        self.assertEqual(self.m._cfg_int(None, 4), 4)

    def test_tail_lines_keeps_last_lines(self):
        with tempfile.NamedTemporaryFile('w', encoding='utf-8', delete=False) as f:
            path = f.name
            f.write(''.join(f'line{i}\n' for i in range(1000)))
            f.write('partial')
        self.addCleanup(os.unlink, path)
        lines = self.m._read_tail_lines(path, 500)
        self.assertEqual(len(lines), 500)
        self.assertEqual(lines[0], 'line501\n')
        self.assertEqual(lines[-1], 'partial\n')

    def test_response_text_decodes_gbk(self):
        headers = {'Content-Type': 'text/html; charset=gbk'}
        resp = self.m._Response(200, '中文'.encode('gbk'), headers)
        self.assertEqual(resp.text, '中文')
        self.assertIs(resp.text, resp.text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
