"""Static safety contract for the receive-only Piper node."""

import ast
from pathlib import Path


PACKAGE_ROOT = Path(__file__).parents[1]
NODE_PATH = PACKAGE_ROOT / 'pi05_piper_readonly' / 'readonly_state_node.py'


def _calls(tree):
    for item in ast.walk(tree):
        if isinstance(item, ast.Call):
            yield item


def test_no_ros_command_ingress_or_can_send_calls():
    tree = ast.parse(NODE_PATH.read_text())
    called_attributes = {
        call.func.attr
        for call in _calls(tree)
        if isinstance(call.func, ast.Attribute)
    }
    forbidden = {
        'create_subscription',
        'create_service',
        'send',
        'SendCanMessage',
        'EnableArm',
        'DisableArm',
        'MotionCtrl_1',
        'MotionCtrl_2',
        'JointCtrl',
        'EndPoseCtrl',
        'GripperCtrl',
    }
    assert called_attributes.isdisjoint(forbidden)


def test_sdk_connection_explicitly_disables_piper_init():
    tree = ast.parse(NODE_PATH.read_text())
    connect_calls = [
        call for call in _calls(tree)
        if isinstance(call.func, ast.Attribute)
        and call.func.attr == 'ConnectPort'
    ]
    assert len(connect_calls) == 1
    keywords = {keyword.arg: keyword.value
                for keyword in connect_calls[0].keywords}
    assert isinstance(keywords['piper_init'], ast.Constant)
    assert keywords['piper_init'].value is False


def test_runtime_parameter_services_are_disabled():
    tree = ast.parse(NODE_PATH.read_text())
    init_calls = [
        call for call in _calls(tree)
        if isinstance(call.func, ast.Attribute)
        and call.func.attr == '__init__'
    ]
    assert len(init_calls) == 1
    keywords = {keyword.arg: keyword.value
                for keyword in init_calls[0].keywords}
    assert isinstance(keywords['start_parameter_services'], ast.Constant)
    assert keywords['start_parameter_services'].value is False
