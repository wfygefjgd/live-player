"""频道源管理模块"""
import requests
import re
from typing import List, Dict, Tuple
import time


class Channel:
    """频道类"""
    def __init__(self, name: str, url: str, group: str = "", logo: str = ""):
        self.name = name
        self.url = url
        self.group = group
        self.logo = logo
        self.is_available = None
        self.response_time = 0


class ChannelManager:
    """频道源管理器"""
    
    # 预置的直播源列表
    SOURCE_URLS = [
        "https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8",
        "https://raw.githubusercontent.com/Supprise0901/TVBox_live/main/live.txt",
        "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/tv.m3u",
    ]
    
    # GitHub镜像源
    MIRROR_URLS = [
        "https://ghfast.top/raw.githubusercontent.com/",
        "https://raw.gitmirror.com/",
        "https://raw.kkgithub.com/",
    ]
    
    def __init__(self):
        self.channels: List[Channel] = []
        self.groups: Dict[str, List[Channel]] = {}
        self.current_source_index = 0
        
    def get_mirrored_url(self, url: str) -> List[str]:
        """生成带镜像的URL列表"""
        urls = [url]
        for mirror in self.MIRROR_URLS:
            if "raw.githubusercontent.com" in url:
                mirrored = url.replace("https://raw.githubusercontent.com/", mirror)
                urls.append(mirrored)
        return urls
    
    def fetch_source(self, url: str = None) -> bool:
        """获取直播源"""
        if url is None:
            url = self.SOURCE_URLS[self.current_source_index % len(self.SOURCE_URLS)]
        
        urls_to_try = self.get_mirrored_url(url)
        
        for try_url in urls_to_try:
            try:
                print(f"正在获取源: {try_url}")
                headers = {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                }
                response = requests.get(try_url, headers=headers, timeout=15)
                response.raise_for_status()
                
                content = response.text
                if content:
                    self.parse_m3u(content)
                    print(f"成功获取 {len(self.channels)} 个频道")
                    return True
            except Exception as e:
                print(f"获取失败 {try_url}: {e}")
                continue
        
        return False
    
    def parse_m3u(self, content: str) -> None:
        """解析M3U格式的直播源"""
        self.channels.clear()
        self.groups.clear()
        
        lines = content.strip().split('\n')
        current_channel = None
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
                
            if line.startswith('#EXTINF:'):
                # 解析频道信息
                info = line[8:]
                
                # 提取group-title
                group_match = re.search(r'group-title="([^"]*)"', info)
                group = group_match.group(1) if group_match else "其他频道"
                
                # 提取tvg-logo
                logo_match = re.search(r'tvg-logo="([^"]*)"', info)
                logo = logo_match.group(1) if logo_match else ""
                
                # 提取频道名称(逗号后面的部分)
                name_match = re.search(r',(.+)$', info)
                name = name_match.group(1).strip() if name_match else "未知频道"
                
                current_channel = Channel(name=name, url="", group=group, logo=logo)
            elif line.startswith('#') or not current_channel:
                continue
            else:
                # 这是URL行
                current_channel.url = line
                self.channels.append(current_channel)
                
                # 按组分类
                if current_channel.group not in self.groups:
                    self.groups[current_channel.group] = []
                self.groups[current_channel.group].append(current_channel)
                
                current_channel = None
    
    def check_channel_availability(self, channel: Channel, timeout: int = 5) -> bool:
        """检测频道是否可用"""
        try:
            start_time = time.time()
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            }
            response = requests.head(channel.url, headers=headers, timeout=timeout, allow_redirects=True)
            channel.response_time = int((time.time() - start_time) * 1000)
            channel.is_available = response.status_code == 200
            return channel.is_available
        except:
            channel.is_available = False
            return False
    
    def get_channels_by_group(self, group: str) -> List[Channel]:
        """获取指定组的频道"""
        return self.groups.get(group, [])
    
    def get_all_groups(self) -> List[str]:
        """获取所有分组"""
        return list(self.groups.keys())
    
    def switch_source(self) -> bool:
        """切换到下一个源"""
        self.current_source_index += 1
        return self.fetch_source()
    
    def refresh(self) -> bool:
        """刷新当前源"""
        return self.fetch_source()
