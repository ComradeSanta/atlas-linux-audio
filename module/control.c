// SPDX-License-Identifier: GPL-2.0-only
//
// Copyright(c) 2021-2022 Intel Corporation
//
// Authors: Amadeusz Slawinski <amadeuszx.slawinski@linux.intel.com>
//          Cezary Rojewski <cezary.rojewski@intel.com>
//

#include <linux/cleanup.h>
#include <sound/soc.h>
#include "avs.h"
#include "control.h"
#include "messages.h"
#include "path.h"
#include "topology.h"

static struct avs_dev *avs_get_kcontrol_adev(struct snd_kcontrol *kcontrol)
{
	struct snd_soc_dapm_context *dapm = snd_soc_dapm_kcontrol_to_dapm(kcontrol);
	struct device *dev = snd_soc_dapm_to_dev(dapm);

	return to_avs_dev(dev);
}

static struct avs_path_module *avs_get_volume_module(struct avs_dev *adev, u32 id)
{
	struct avs_path *path;
	struct avs_path_pipeline *ppl;
	struct avs_path_module *mod;

	spin_lock(&adev->path_list_lock);
	list_for_each_entry(path, &adev->path_list, node) {
		list_for_each_entry(ppl, &path->ppl_list, node) {
			list_for_each_entry(mod, &ppl->mod_list, node) {
				guid_t *type = &mod->template->cfg_ext->type;

				if ((guid_equal(type, &AVS_PEAKVOL_MOD_UUID) ||
				     guid_equal(type, &AVS_GAIN_MOD_UUID)) &&
				    mod->template->ctl_id == id) {
					spin_unlock(&adev->path_list_lock);
					return mod;
				}
			}
		}
	}
	spin_unlock(&adev->path_list_lock);

	return NULL;
}

int avs_control_volume_get(struct snd_kcontrol *kctl, struct snd_ctl_elem_value *uctl)
{
	struct soc_mixer_control *mc = (struct soc_mixer_control *)kctl->private_value;
	struct avs_control_data *ctl_data = mc->dobj.private;
	struct avs_path_module *active_module;
	struct avs_volume_cfg *dspvols;
	struct avs_dev *adev;
	size_t num_dspvols;
	int ret, i;

	adev = avs_get_kcontrol_adev(kctl);

	/* Prevent access to modules while path is being constructed. */
	guard(mutex)(&adev->path_mutex);

	active_module = avs_get_volume_module(adev, ctl_data->id);
	if (active_module) {
		ret = avs_ipc_peakvol_get_volume(adev, active_module->module_id,
						 active_module->instance_id, &dspvols,
						 &num_dspvols);
		if (ret)
			return AVS_IPC_RET(ret);

		/* Do not copy more than the control can store. */
		num_dspvols = min_t(u32, num_dspvols, SND_SOC_TPLG_MAX_CHAN);
		for (i = 0; i < num_dspvols; i++)
			ctl_data->values[i] = dspvols[i].target_volume;
		kfree(dspvols);
	}

	memcpy(uctl->value.integer.value, ctl_data->values, sizeof(ctl_data->values));
	return 0;
}

int avs_control_volume_put(struct snd_kcontrol *kctl, struct snd_ctl_elem_value *uctl)
{
	struct avs_path_module *active_module;
	struct avs_control_data *ctl_data;
	struct soc_mixer_control *mc;
	struct avs_dev *adev;
	long *input;
	int ret, i;

	mc = (struct soc_mixer_control *)kctl->private_value;
	ctl_data = mc->dobj.private;
	adev = avs_get_kcontrol_adev(kctl);
	input = uctl->value.integer.value;
	i = 0;

	/* mc->num_channels can be 0. */
	do {
		if (input[i] < mc->min || input[i] > mc->max)
			return -EINVAL;
	} while (++i < mc->num_channels);

	if (!memcmp(ctl_data->values, input, sizeof(ctl_data->values)))
		return 0;

	/* Prevent access to modules while path is being constructed. */
	guard(mutex)(&adev->path_mutex);

	active_module = avs_get_volume_module(adev, ctl_data->id);
	if (active_module) {
		ret = avs_peakvol_set_volume(adev, active_module, mc, input);
		if (ret)
			return ret;
	}

	memcpy(ctl_data->values, input, sizeof(ctl_data->values));
	return 1;
}

int avs_control_volume_info(struct snd_kcontrol *kctl, struct snd_ctl_elem_info *uinfo)
{
	struct soc_mixer_control *mc = (struct soc_mixer_control *)kctl->private_value;

	uinfo->type = SNDRV_CTL_ELEM_TYPE_INTEGER;
	uinfo->count = max_t(u32, 1, mc->num_channels);
	uinfo->value.integer.min = 0;
	uinfo->value.integer.max = mc->max;
	return 0;
}

int avs_control_mute_get(struct snd_kcontrol *kctl, struct snd_ctl_elem_value *uctl)
{
	struct soc_mixer_control *mc = (struct soc_mixer_control *)kctl->private_value;
	struct avs_control_data *ctl_data = mc->dobj.private;
	struct avs_path_module *active_module;
	struct avs_mute_cfg *dspmutes;
	struct avs_dev *adev;
	size_t num_dspmutes;
	int ret, i;

	adev = avs_get_kcontrol_adev(kctl);

	/* Prevent access to modules while path is being constructed. */
	guard(mutex)(&adev->path_mutex);

	active_module = avs_get_volume_module(adev, ctl_data->id);
	if (active_module) {
		ret = avs_ipc_peakvol_get_mute(adev, active_module->module_id,
					       active_module->instance_id, &dspmutes,
					       &num_dspmutes);
		if (ret)
			return AVS_IPC_RET(ret);

		/* Do not copy more than the control can store. */
		num_dspmutes = min_t(u32, num_dspmutes, SND_SOC_TPLG_MAX_CHAN);
		for (i = 0; i < num_dspmutes; i++)
			ctl_data->values[i] = !dspmutes[i].mute;
		kfree(dspmutes);
	}

	memcpy(uctl->value.integer.value, ctl_data->values, sizeof(ctl_data->values));
	return 0;
}

int avs_control_mute_put(struct snd_kcontrol *kctl, struct snd_ctl_elem_value *uctl)
{
	struct avs_path_module *active_module;
	struct avs_control_data *ctl_data;
	struct soc_mixer_control *mc;
	struct avs_dev *adev;
	long *input;
	int ret, i;

	mc = (struct soc_mixer_control *)kctl->private_value;
	ctl_data = mc->dobj.private;
	adev = avs_get_kcontrol_adev(kctl);
	input = uctl->value.integer.value;
	i = 0;

	/* mc->num_channels can be 0. */
	do {
		if (input[i] < mc->min || input[i] > mc->max)
			return -EINVAL;
	} while (++i < mc->num_channels);

	if (!memcmp(ctl_data->values, input, sizeof(ctl_data->values)))
		return 0;

	/* Prevent access to modules while path is being constructed. */
	guard(mutex)(&adev->path_mutex);

	active_module = avs_get_volume_module(adev, ctl_data->id);
	if (active_module) {
		ret = avs_peakvol_set_mute(adev, active_module, mc, input);
		if (ret)
			return ret;
	}

	memcpy(ctl_data->values, input, sizeof(ctl_data->values));
	return 1;
}

int avs_control_mute_info(struct snd_kcontrol *kctl, struct snd_ctl_elem_info *uinfo)
{
	struct soc_mixer_control *mc = (struct soc_mixer_control *)kctl->private_value;

	uinfo->type = SNDRV_CTL_ELEM_TYPE_BOOLEAN;
	uinfo->count = max_t(u32, 1, mc->num_channels);
	uinfo->value.integer.min = 0;
	uinfo->value.integer.max = mc->max;
	return 0;
}

/*
 * ChromeOS-compatible TLV bytes controls.  The payload is an ALSA TLV whose
 * value part is:
 *
 *   struct avs_kcontrol_tlv_data {
 *           u32 flags;      // AVS_KCTRL_TLV_FLAGS_*
 *           u32 count;      // number of avs_tlv entries
 *           struct avs_tlv tlv[];
 *   };
 *
 * Each avs_tlv is forwarded verbatim as an AVS large-config message to the
 * module instance whose topology ctl_id matches the kcontrol id.  With
 * AVS_KCTRL_TLV_FLAGS_CACHE the payload is kept and re-applied whenever a
 * matching module instance is created (the blobs are pushed from the UCM
 * verb sequence before the playback path exists).
 */
struct avs_kcontrol_tlv_data {
	u32 flags;
	u32 count;
	struct avs_tlv tlv[];
} __packed;

#define AVS_KCTRL_TLV_FLAGS_CACHE	BIT(0)

static struct avs_path_module *
avs_get_module_by_ctl_id(struct avs_dev *adev, u32 id)
{
	struct avs_path *path;
	struct avs_path_pipeline *ppl;
	struct avs_path_module *mod;

	spin_lock(&adev->path_list_lock);
	list_for_each_entry(path, &adev->path_list, node) {
		list_for_each_entry(ppl, &path->ppl_list, node) {
			list_for_each_entry(mod, &ppl->mod_list, node) {
				if (mod->template->ctl_id == id) {
					spin_unlock(&adev->path_list_lock);
					return mod;
				}
			}
		}
	}
	spin_unlock(&adev->path_list_lock);

	return NULL;
}

static int avs_tlv_set_large_config(struct avs_dev *adev, struct avs_path_module *mod,
				    struct avs_kcontrol_tlv_data *data)
{
	struct avs_tlv *tlv = data->tlv;
	int ret, i;

	for (i = 0; i < data->count; i++) {
		ret = avs_ipc_set_large_config(adev, mod->module_id, mod->instance_id,
					       tlv->type, (u8 *)tlv->value, tlv->length);
		if (ret)
			return ret;

		tlv = (struct avs_tlv *)((u8 *)tlv + sizeof(*tlv) + tlv->length);
	}

	return 0;
}

int avs_tlv_control_set(struct snd_kcontrol *kctl, const unsigned int __user *data,
			unsigned int size)
{
	struct avs_control_data *ctl_data;
	struct avs_kcontrol_tlv_data *tlv_data;
	struct avs_path_module *mod;
	const struct avs_tlv *iter;
	struct snd_ctl_tlv tlv;
	struct avs_dev *adev;
	size_t check_size;
	int ret = 0;
	int i;

	ctl_data = ((struct soc_bytes_ext *)kctl->private_value)->dobj.private;
	if (!ctl_data || !ctl_data->adev)
		return -EINVAL;
	adev = ctl_data->adev;

	if (size < sizeof(tlv))
		return -EINVAL;
	if (copy_from_user(&tlv, data, sizeof(tlv)))
		return -EFAULT;
	if (tlv.length != size - sizeof(tlv))
		return -EINVAL;
	if (tlv.length <= offsetof(struct avs_kcontrol_tlv_data, tlv))
		return -EINVAL;

	tlv_data = kzalloc(tlv.length, GFP_KERNEL);
	if (!tlv_data)
		return -ENOMEM;
	if (copy_from_user(tlv_data, (const u8 __user *)data + sizeof(tlv), tlv.length)) {
		ret = -EFAULT;
		goto err_free;
	}

	iter = tlv_data->tlv;
	check_size = offsetof(struct avs_kcontrol_tlv_data, tlv);
	for (i = 0; i < tlv_data->count; i++) {
		check_size += sizeof(*iter) + iter->length;
		if (check_size > tlv.length) {
			ret = -EINVAL;
			goto err_free;
		}
		iter = (const struct avs_tlv *)((const u8 *)iter + sizeof(*iter) + iter->length);
	}

	mutex_lock(&adev->path_mutex);
	mod = avs_get_module_by_ctl_id(adev, ctl_data->id);
	if (mod)
		ret = avs_tlv_set_large_config(adev, mod, tlv_data);
	else if (!(tlv_data->flags & AVS_KCTRL_TLV_FLAGS_CACHE))
		ret = -EINVAL;
	mutex_unlock(&adev->path_mutex);
	if (ret)
		goto err_free;

	if (tlv_data->flags & AVS_KCTRL_TLV_FLAGS_CACHE) {
		kfree(ctl_data->tlv_data);
		ctl_data->tlv_data = tlv_data;
		tlv_data = NULL;
	}

err_free:
	kfree(tlv_data);
	return ret;
}

int avs_kcontrol_tlv_module_init(struct avs_dev *adev, struct avs_path_module *mod)
{
	struct avs_tplg_module *t = mod->template;
	struct avs_control_data *ctl_data;
	struct avs_tplg *tplg;

	if (!t->ctl_id)
		return 0;

	tplg = t->owner->owner->owner->owner;
	list_for_each_entry(ctl_data, &tplg->kctrl_list, node) {
		if (ctl_data->id != t->ctl_id)
			continue;
		if (!ctl_data->tlv_data)
			return 0;

		return avs_tlv_set_large_config(adev, mod, ctl_data->tlv_data);	}

	return 0;
}
